// ChappieViewModel.swift
// Chappie
//
// Main ViewModel of the Chappie application.
// Manages UI state, message history, initializes services,
// and coordinates the AI orchestrator.
//
// IT-09: syncActiveMemoryContext() also calls ts.setProjectSettings()
// so ToolExecutionService knows project settings for permission checks.
//
// IT-10: Universal AI Provider.
// - AITunnelClient replaced with AIClient (provider-agnostic)
// - AIProviderStore manages provider list + Keychain keys
// - activeProvider: AIProvider? — currently selected provider for the active thread
// - activeModelName: String? — currently selected model within the active provider
// - createNewThread() triggers provider+model selection sheet before entering chat
//
// ORPHANED THREADS:
// Deletion of providers/models is always allowed.
// isThreadOrphaned computed property detects when activeProvider or activeModelName
// is missing from the current providers list. Chat view shows a warning banner.
//
// CANCEL SUPPORT:
// currentRequestTask holds the active Task from send().
// cancelCurrentRequest() cancels it — triggers CancellationError inside process().
// AIOrchestrator propagates Swift structured concurrency cancellation automatically.

import SwiftUI
import ChappieCore
import SwiftData

@Observable
@MainActor
final class ChappieViewModel {

    // MARK: - State

    var workspaceURL: URL?

    var messages: [ChatMessage] = [] {
        didSet { saveMessages() }
    }

    var visibleMessages: [ChatMessage] {
        let onlyMessages = messages.filter { msg in
            if case .message = msg { return true }
            return false
        }
        return Array(onlyMessages.suffix(30))
    }

    var isThinking = false
    var streamingText: String = ""
    var runningCost: Double = 0.0
    var currentToolCall: String? = nil

    var currentBalance: Double? {
        didSet { UserDefaults.standard.set(currentBalance, forKey: "savedBalance") }
    }

    // MARK: - Active Request Task
    //
    // Stored so cancelCurrentRequest() can cancel it at any time.
    // Nil when no request is in flight.
    private var currentRequestTask: Task<Void, Never>? = nil

    // MARK: - Threads (IT-05)

    var threads: [ThreadMetadata] = []
    var activeThread: ThreadMetadata? = nil

    // MARK: - Projects in thread (IT-06)

    var activeProjects: [ProjectMetadata] = []

    // MARK: - Active thread settings (IT-02)

    var activeThreadSettings: ThreadSettings = ThreadSettings()

    private var activeConfig: AppConfig {
        AppConfig(settings: activeThreadSettings)
    }

    // MARK: - Memory context for system prompt (IT-03, IT-05, IT-08, IT-09)

    var activeMemoryContext: MemoryContext = .empty

    // MARK: - IT-10: AI Providers

    /// All configured AI providers.
    var providers: [AIProvider] = []

    /// The provider currently active for this thread.
    /// nil = no provider configured yet (onboarding required).
    var activeProvider: AIProvider? = nil

    /// The model name currently active for this thread.
    /// Must be one of activeProvider.models, or the thread is considered orphaned.
    var activeModelName: String? = nil

    /// True when the active thread's provider or model is no longer available.
    /// Chat view shows a warning banner and model picker to recover.
    var isThreadOrphaned: Bool {
        guard let provider = activeProvider else {
            return activeThreadSettings.activeProviderId != nil
        }
        guard providers.contains(where: { $0.id == provider.id }) else { return true }
        if let model = activeModelName {
            return !provider.models.contains(model)
        }
        return false
    }

    /// Controls the new-thread provider+model picker sheet (IT-10).
    var showNewThreadProviderPicker: Bool = false

    /// Pending thread waiting for provider+model selection (IT-10).
    var pendingNewThread: ThreadMetadata? = nil

    // MARK: - Dependencies

    private var fileSystem: FileSystemManager?
    private var memoryManager: MemoryManager?
    private var toolService: ToolExecutionService?

    private var aiClient: AIClient?
    private var orchestrator: AIOrchestrator?
    private var chatHistoryManager: ChatHistoryManager

    // MARK: - SwiftData

    private var modelContainer: ModelContainer?
    private var memoryStore: MemoryStore?
    private var threadStore: ThreadStore?
    private var projectStore: ProjectStore?
    var providerStore: AIProviderStore?

    // MARK: - Init

    public init() {
        self.chatHistoryManager = ChatHistoryManager.shared
        loadMessages()

        if let savedBalance = UserDefaults.standard.object(forKey: "savedBalance") as? Double {
            self.currentBalance = savedBalance
        }

        loadWorkspaceWithSecurityScope()
    }

    // MARK: - Connect SwiftData

    func setModelContainer(_ container: ModelContainer) {
        guard self.modelContainer == nil else { return }

        self.modelContainer = container

        let store = MemoryStore(modelContainer: container)
        self.memoryStore = store

        let tStore = ThreadStore(modelContainer: container)
        self.threadStore = tStore

        let pStore = ProjectStore(modelContainer: container)
        self.projectStore = pStore

        let provStore = AIProviderStore(modelContainer: container)
        self.providerStore = provStore

        if let mm = memoryManager {
            Task { await mm.setMemoryStore(store) }
        }

        print("[ChappieViewModel] ModelContainer connected")

        if let ts = toolService {
            registerProjectToolHandlers(toolService: ts, projectStore: pStore, threadStore: tStore)
        }

        Task {
            await runMigrationIfNeeded(threadStore: tStore, memoryStore: store)
            await loadProvidersAndSetActive(from: provStore)
            await loadThreadsAndSelectActive(from: tStore)
        }
    }

    // MARK: - IT-10: User Name

    /// Saves the user's name directly to global SwiftData memory.
    /// Called from OnboardingView and SettingsView — no UserDefaults staging needed.
    func saveUserName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let store = memoryStore else {
            print("[ChappieViewModel] MemoryStore not ready, retrying saveUserName in 1s")
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.saveUserName(trimmed)
            }
            return
        }

        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\\\"")

        Task {
            do {
                try await store.saveEntry(
                    key: "user_name",
                    type: "fact",
                    jsonString: "{\"name\": \"\(escaped)\"}",
                    scope: "global"
                )
                print("[ChappieViewModel] User name saved to global memory: \(trimmed)")
            } catch {
                print("[ChappieViewModel] Failed to save user name: \(error)")
            }
        }
    }

    /// Reads the user's name from global SwiftData memory.
    /// Parses JSON string {"name": "..."} to extract the value.
    /// Returns nil if not set yet.
    func loadUserName() async -> String? {
        guard let store = memoryStore else { return nil }
        do {
            guard let json = try await store.readEntry(key: "user_name", scope: "global") else {
                return nil
            }
            // Parse {"name": "Sergey"} — simple extraction without full JSON decoder
            guard let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let name = obj["name"] else {
                return nil
            }
            return name
        } catch {
            print("[ChappieViewModel] Failed to load user name: \(error)")
            return nil
        }
    }

    // MARK: - IT-10: Provider Management

    /// Loads all providers and sets the active one from the default.
    private func loadProvidersAndSetActive(from store: AIProviderStore) async {
        do {
            let loaded = try await store.loadProviders()
            self.providers = loaded
            if let defaultProvider = try await store.loadDefaultProvider() {
                let defaultModel = defaultProvider.models.first
                await switchProvider(defaultProvider, modelName: defaultModel, from: store)
            }
            print("[ChappieViewModel] Loaded \(loaded.count) providers")
        } catch {
            print("[ChappieViewModel] Failed to load providers: \(error)")
        }
    }

    /// Switches the active AI provider and model — recreates AIClient and AIOrchestrator.
    func switchProvider(_ provider: AIProvider, modelName: String?, from store: AIProviderStore? = nil) async {
        let provStore = store ?? self.providerStore
        guard let provStore else { return }

        let apiKey = await provStore.loadApiKey(for: provider.id) ?? ""
        let model = modelName ?? provider.models.first ?? ""
        let client = AIClient(endpoint: provider.endpoint, apiKey: apiKey, modelName: model)
        self.aiClient = client
        self.activeProvider = provider
        self.activeModelName = model.isEmpty ? nil : model

        if let ts = toolService, let fs = fileSystem, let mm = memoryManager {
            self.orchestrator = AIOrchestrator(
                aiClient: client,
                toolService: ts,
                fileSystem: fs,
                memoryManager: mm
            )
        }

        if activeThread != nil {
            var settings = activeThreadSettings
            settings.activeProviderId = provider.id
            settings.activeModelName = model.isEmpty ? nil : model
            activeThreadSettings = settings
            if let threadId = activeThread?.id, let tStore = threadStore {
                try? await tStore.updateSettings(settings, forThreadId: threadId)
            }
        }

        print("[ChappieViewModel] Switched to provider: \(provider.displayName) / model: \(model)")
    }

    /// Switches provider by ID — used from ModelPickerRow.
    func switchProvider(id: UUID) {
        guard let provider = providers.first(where: { $0.id == id }),
              let provStore = providerStore else { return }
        let model = provider.models.first
        Task {
            await switchProvider(provider, modelName: model, from: provStore)
        }
    }

    /// Switches to a specific model within the current provider.
    func switchModel(to modelName: String) {
        guard let provider = activeProvider,
              let provStore = providerStore else { return }
        Task {
            await switchProvider(provider, modelName: modelName, from: provStore)
        }
    }

    /// Reloads providers list from store (called after add/edit/delete in settings).
    func reloadProviders() {
        guard let store = providerStore else { return }
        Task {
            do {
                let loaded = try await store.loadProviders()
                self.providers = loaded
                if let active = activeProvider,
                   let updated = loaded.first(where: { $0.id == active.id }) {
                    self.activeProvider = updated
                }
                print("[ChappieViewModel] Providers reloaded: \(loaded.count)")
            } catch {
                print("[ChappieViewModel] Failed to reload providers: \(error)")
            }
        }
    }

    // MARK: - Register Project Tool Handlers (IT-07)

    private func registerProjectToolHandlers(
        toolService ts: ToolExecutionService,
        projectStore pStore: ProjectStore,
        threadStore tStore: ThreadStore
    ) {
        Task {
            await ts.registerProjectHandlers(

                addProject: { [weak self] displayName in
                    return await withCheckedContinuation { continuation in
                        Task { @MainActor [weak self] in
                            guard let self else {
                                continuation.resume(returning: "Error: ViewModel released.")
                                return
                            }
                            let activeThread = self.activeThread
                            let result = await ChappieViewModel.performAddProjectByName(
                                displayName: displayName,
                                projectStore: pStore,
                                threadStore: tStore,
                                activeThread: activeThread,
                                onUpdate: { [weak self] updatedThread in
                                    Task { @MainActor [weak self] in
                                        await self?.reloadAfterProjectChange(
                                            updatedThread: updatedThread,
                                            projectStore: pStore,
                                            threadStore: tStore
                                        )
                                    }
                                }
                            )
                            continuation.resume(returning: result)
                        }
                    }
                },

                removeProject: { [weak self] displayName in
                    return await withCheckedContinuation { continuation in
                        Task { @MainActor [weak self] in
                            guard let self else {
                                continuation.resume(returning: "Error: ViewModel released.")
                                return
                            }
                            let activeThread = self.activeThread
                            let activeProjects = self.activeProjects
                            let result = await ChappieViewModel.performRemoveProjectByName(
                                displayName: displayName,
                                projectStore: pStore,
                                threadStore: tStore,
                                activeThread: activeThread,
                                activeProjects: activeProjects,
                                onUpdate: { [weak self] updatedThread in
                                    Task { @MainActor [weak self] in
                                        await self?.reloadAfterProjectChange(
                                            updatedThread: updatedThread,
                                            projectStore: pStore,
                                            threadStore: tStore
                                        )
                                    }
                                }
                            )
                            continuation.resume(returning: result)
                        }
                    }
                },

                listProjects: { [weak self] in
                    return await withCheckedContinuation { continuation in
                        Task { @MainActor [weak self] in
                            guard let self else {
                                continuation.resume(returning: "Error: ViewModel released.")
                                return
                            }
                            let names = self.activeProjects.map { $0.displayName }
                            if names.isEmpty {
                                continuation.resume(returning: "No projects in current thread.")
                            } else {
                                let list = names.enumerated()
                                    .map { "\($0.offset + 1). \($0.element)" }
                                    .joined(separator: "\n")
                                continuation.resume(returning: "Projects in current thread:\n\(list)")
                            }
                        }
                    }
                }
            )
            print("[ChappieViewModel] Project tool handlers registered")
        }
    }

    private static func performAddProjectByName(
        displayName: String,
        projectStore: ProjectStore,
        threadStore: ThreadStore,
        activeThread: ThreadMetadata?,
        onUpdate: @escaping @Sendable (ThreadMetadata) -> Void
    ) async -> String {
        guard let thread = activeThread else {
            return "Error: No active thread."
        }

        do {
            let allProjects = try await projectStore.loadProjects()
            let threadProjects = try await projectStore.loadProjects(ids: thread.projectIds)

            if threadProjects.contains(where: { $0.displayName == displayName }) {
                return "Project '\(displayName)' is already added to the current thread."
            }

            let projectId: UUID
            if let existing = allProjects.first(where: { $0.displayName == displayName }) {
                projectId = existing.id
            } else {
                projectId = try await projectStore.addProject(
                    displayName: displayName,
                    bookmarkData: Data()
                )
            }

            var updatedIds = thread.projectIds
            updatedIds.append(projectId)
            try await threadStore.updateProjectBindings(updatedIds, forThreadId: thread.id)

            let refreshed = try await threadStore.loadThreads()
            if let updatedThread = refreshed.first(where: { $0.id == thread.id }) {
                onUpdate(updatedThread)
            }

            return "Project '\(displayName)' added to the current thread."
        } catch {
            return "Error adding project '\(displayName)': \(error.localizedDescription)"
        }
    }

    private static func performRemoveProjectByName(
        displayName: String,
        projectStore: ProjectStore,
        threadStore: ThreadStore,
        activeThread: ThreadMetadata?,
        activeProjects: [ProjectMetadata],
        onUpdate: @escaping @Sendable (ThreadMetadata) -> Void
    ) async -> String {
        guard let thread = activeThread else {
            return "Error: No active thread."
        }

        guard let project = activeProjects.first(where: { $0.displayName == displayName }) else {
            return "Project '\(displayName)' not found in current thread."
        }

        do {
            var updatedIds = thread.projectIds
            updatedIds.removeAll { $0 == project.id }
            try await threadStore.updateProjectBindings(updatedIds, forThreadId: thread.id)

            let refreshed = try await threadStore.loadThreads()
            if let updatedThread = refreshed.first(where: { $0.id == thread.id }) {
                onUpdate(updatedThread)
            }

            return "Project '\(displayName)' removed from current thread."
        } catch {
            return "Error removing project '\(displayName)': \(error.localizedDescription)"
        }
    }

    private func reloadAfterProjectChange(
        updatedThread: ThreadMetadata,
        projectStore: ProjectStore,
        threadStore: ThreadStore
    ) async {
        do {
            let refreshed = try await threadStore.loadThreads()
            self.threads = refreshed

            if activeThread?.id == updatedThread.id {
                self.activeThread = updatedThread
                await loadProjectsForThread(updatedThread)
                buildAndSyncMemoryContext()
                await syncActiveMemoryContext()
            }
        } catch {
            print("[ChappieViewModel] Error reloading after project change: \(error)")
        }
    }

    // MARK: - Memory Context (IT-08, IT-09)

    private func buildAndSyncMemoryContext() {
        let projectInfos = activeProjects.map { project in
            MemoryContext.ProjectInfo(
                id: project.id,
                name: project.displayName,
                settings: project.settings
            )
        }

        self.activeMemoryContext = MemoryContext(
            threadId: activeThread?.id,
            projectInfos: projectInfos
        )
    }

    private func syncActiveMemoryContext() async {
        guard let ts = toolService else { return }

        let projectInfos = activeProjects.map { project in
            ActiveMemoryContext.ProjectInfo(id: project.id, name: project.displayName)
        }

        let context = ActiveMemoryContext(
            threadId: activeThread?.id,
            projects: projectInfos
        )

        await ts.setActiveMemoryContext(context)

        let settingsMap = Dictionary(
            uniqueKeysWithValues: activeProjects.map { ($0.id, $0.settings) }
        )
        await ts.setProjectSettings(settingsMap)
    }

    // MARK: - Thread Management (IT-05)

    private func loadThreadsAndSelectActive(from store: ThreadStore) async {
        do {
            let loaded = try await store.loadThreads()
            self.threads = loaded

            if loaded.isEmpty {
                let newId = try await store.createThread(title: "Новый тред")
                let refreshed = try await store.loadThreads()
                self.threads = refreshed
                if let newThread = refreshed.first(where: { $0.id == newId }) {
                    await selectThread(newThread)
                }
            } else if let current = activeThread,
                      let updated = loaded.first(where: { $0.id == current.id }) {
                self.activeThread = updated
                buildAndSyncMemoryContext()
            } else {
                await selectThread(loaded[0])
            }
        } catch {
            print("[ChappieViewModel] Error loading threads: \(error)")
        }
    }

    func selectThread(_ thread: ThreadMetadata) async {
        guard let store = threadStore else { return }

        self.activeThread = thread

        do {
            let settings = try await store.loadSettings(forThreadId: thread.id)
            self.activeThreadSettings = settings

            if let providerId = settings.activeProviderId,
               let provider = providers.first(where: { $0.id == providerId }) {
                await switchProvider(provider, modelName: settings.activeModelName)
            } else if activeProvider == nil, let provStore = providerStore {
                if let defaultProvider = try? await provStore.loadDefaultProvider() {
                    await switchProvider(defaultProvider, modelName: defaultProvider.models.first, from: provStore)
                }
            }

            let loaded = try await store.loadMessages(
                fromThreadId: thread.id,
                as: ChatMessage.self
            )

            self.isLoadingThread = true
            self.messages = loaded
            self.isLoadingThread = false

            print("[ChappieViewModel] Thread '\(thread.title)' selected (\(loaded.count) messages)")
        } catch {
            print("[ChappieViewModel] Error loading thread '\(thread.title)': \(error)")
        }

        await loadProjectsForThread(thread)
        buildAndSyncMemoryContext()
        await syncActiveMemoryContext()
    }

    private var isLoadingThread: Bool = false

    func createNewThread() {
        guard let store = threadStore else { return }

        Task {
            do {
                let newId = try await store.createThread(title: "Новый тред")
                let refreshed = try await store.loadThreads()
                self.threads = refreshed

                if let newThread = refreshed.first(where: { $0.id == newId }) {
                    if !providers.isEmpty {
                        self.pendingNewThread = newThread
                        self.showNewThreadProviderPicker = true
                    } else {
                        await selectThread(newThread)
                        self.isLoadingThread = true
                        self.messages = []
                        self.isLoadingThread = false
                        self.activeProjects = []
                        buildAndSyncMemoryContext()
                        await syncActiveMemoryContext()
                    }
                }

                print("[ChappieViewModel] New thread created")
            } catch {
                print("[ChappieViewModel] Error creating thread: \(error)")
            }
        }
    }

    func confirmNewThread(with providerId: UUID, modelName: String) async {
        guard let thread = pendingNewThread else { return }
        self.pendingNewThread = nil
        self.showNewThreadProviderPicker = false

        if let provider = providers.first(where: { $0.id == providerId }) {
            await switchProvider(provider, modelName: modelName)
        }

        await selectThread(thread)
        self.isLoadingThread = true
        self.messages = []
        self.isLoadingThread = false
        self.activeProjects = []
        buildAndSyncMemoryContext()
        await syncActiveMemoryContext()
    }

    func cancelNewThread() {
        guard let thread = pendingNewThread else { return }
        self.pendingNewThread = nil
        self.showNewThreadProviderPicker = false

        guard let store = threadStore else { return }
        Task {
            try? await store.deleteThread(id: thread.id)
            let refreshed = try? await store.loadThreads()
            if let refreshed { self.threads = refreshed }
        }
    }

    func deleteThread(_ thread: ThreadMetadata) {
        guard let store = threadStore else { return }

        Task {
            do {
                try await store.deleteThread(id: thread.id)
                let refreshed = try await store.loadThreads()
                self.threads = refreshed

                if activeThread?.id == thread.id {
                    if let first = refreshed.first {
                        await selectThread(first)
                    } else {
                        let newId = try await store.createThread(title: "Новый тред")
                        let withNew = try await store.loadThreads()
                        self.threads = withNew
                        if let newThread = withNew.first(where: { $0.id == newId }) {
                            await selectThread(newThread)
                        }
                    }
                }

                print("[ChappieViewModel] Thread '\(thread.title)' deleted")
            } catch {
                print("[ChappieViewModel] Error deleting thread: \(error)")
            }
        }
    }

    func renameThread(_ thread: ThreadMetadata, newTitle: String) {
        guard let store = threadStore else { return }

        Task {
            do {
                try await store.renameThread(id: thread.id, title: newTitle)
                let refreshed = try await store.loadThreads()
                self.threads = refreshed

                if activeThread?.id == thread.id,
                   let updated = refreshed.first(where: { $0.id == thread.id }) {
                    self.activeThread = updated
                }
            } catch {
                print("[ChappieViewModel] Error renaming thread: \(error)")
            }
        }
    }

    // MARK: - Project Management (IT-06)

    private func loadProjectsForThread(_ thread: ThreadMetadata) async {
        guard let pStore = projectStore else {
            self.activeProjects = []
            return
        }

        guard !thread.projectIds.isEmpty else {
            self.activeProjects = []
            return
        }

        do {
            let projects = try await pStore.loadProjects(ids: thread.projectIds)
            self.activeProjects = projects
            print("[ChappieViewModel] Loaded \(projects.count) projects for thread '\(thread.title)'")
        } catch {
            print("[ChappieViewModel] Error loading thread projects: \(error)")
            self.activeProjects = []
        }
    }

    func addProject(url: URL) {
        guard let pStore = projectStore,
              let tStore = threadStore,
              let thread = activeThread else { return }

        Task {
            do {
                let bookmarkData: Data
                do {
                    bookmarkData = try url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                } catch {
                    bookmarkData = try url.bookmarkData(
                        options: [],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                }

                let displayName = url.lastPathComponent

                let alreadyAdded = activeProjects.contains { $0.displayName == displayName }
                guard !alreadyAdded else {
                    print("[ChappieViewModel] Project '\(displayName)' already added")
                    return
                }

                let projectId = try await pStore.addProject(
                    displayName: displayName,
                    bookmarkData: bookmarkData
                )

                var updatedIds = thread.projectIds
                updatedIds.append(projectId)
                try await tStore.updateProjectBindings(updatedIds, forThreadId: thread.id)

                let refreshed = try await tStore.loadThreads()
                self.threads = refreshed

                if let updatedThread = refreshed.first(where: { $0.id == thread.id }) {
                    self.activeThread = updatedThread
                    await loadProjectsForThread(updatedThread)
                    buildAndSyncMemoryContext()
                    await syncActiveMemoryContext()
                }

                print("[ChappieViewModel] Project '\(displayName)' added to thread '\(thread.title)'")
            } catch {
                print("[ChappieViewModel] Error adding project: \(error)")
            }
        }
    }

    func removeProject(id projectId: UUID) {
        guard let tStore = threadStore,
              let thread = activeThread else { return }

        Task {
            do {
                var updatedIds = thread.projectIds
                updatedIds.removeAll { $0 == projectId }
                try await tStore.updateProjectBindings(updatedIds, forThreadId: thread.id)

                let refreshed = try await tStore.loadThreads()
                self.threads = refreshed

                if let updatedThread = refreshed.first(where: { $0.id == thread.id }) {
                    self.activeThread = updatedThread
                    await loadProjectsForThread(updatedThread)
                    buildAndSyncMemoryContext()
                    await syncActiveMemoryContext()
                }

                print("[ChappieViewModel] Project removed from thread '\(thread.title)'")
            } catch {
                print("[ChappieViewModel] Error removing project from thread: \(error)")
            }
        }
    }

    // MARK: - IT-09: Update Project Settings

    func updateProjectSettings(_ settings: ProjectSettings, forProjectId projectId: UUID) {
        guard let pStore = projectStore,
              let thread = activeThread else { return }

        Task {
            do {
                try await pStore.updateSettings(settings, forProjectId: projectId)
                await loadProjectsForThread(thread)
                buildAndSyncMemoryContext()
                await syncActiveMemoryContext()
                print("[ChappieViewModel] Project settings updated (id: \(projectId))")
            } catch {
                print("[ChappieViewModel] Error updating project settings: \(error)")
            }
        }
    }

    // MARK: - Workspace Management

    func setWorkspace(_ url: URL) {
        workspaceURL = url
        initializeServices(for: url)
        chatHistoryManager = ChatHistoryManager(workspaceURL: url)
        loadMessages()
        saveWorkspaceWithSecurityScope(url)
        MCPHelperLauncher.shared.restartWithWorkspace(url)

        if messages.isEmpty {
            messages.append(.message(isUser: false, text: "Проект подключен. Я готов к работе!"))
        }
    }

    // MARK: - Send & Cancel

    /// Sends a prompt to the orchestrator.
    /// Stores the Task in currentRequestTask so it can be cancelled at any time.
    func send(prompt: String) {
        guard !prompt.isEmpty else { return }
        guard let orchestrator = orchestrator else {
            messages.append(.message(isUser: false, text: "Ошибка: Оркестратор не инициализирован. Подключите папку с проектом."))
            return
        }

        guard activeProvider != nil else {
            messages.append(.message(isUser: false, text: "⚠️ Нет настроенного AI-провайдера. Откройте настройки и добавьте провайдера."))
            return
        }

        messages.append(.message(isUser: true, text: prompt))
        isThinking = true
        streamingText = ""
        currentToolCall = nil
        runningCost = 0.0

        let networkHistory = buildRawNetworkHistory()
        let config = activeConfig
        let memoryContext = activeMemoryContext
        let activeThreadId = activeThread?.id

        // Store the task so cancelCurrentRequest() can cancel it
        currentRequestTask = Task {
            do {
                let result = try await orchestrator.process(
                    prompt: prompt,
                    history: networkHistory,
                    config: config,
                    memoryContext: memoryContext,
                    onToolCall: { toolName, targetPath in
                        Task { @MainActor in
                            if targetPath.isEmpty {
                                self.currentToolCall = toolName
                            } else {
                                let shortPath = targetPath.split(separator: "/").suffix(2).joined(separator: "/")
                                self.currentToolCall = "\(toolName) → \(shortPath)"
                            }
                        }
                    },
                    onToken: { token in
                        Task { @MainActor in
                            self.streamingText += token
                        }
                    },
                    onCostUpdate: { cumulativeCost in
                        Task { @MainActor in
                            self.runningCost = cumulativeCost
                        }
                    }
                )

                let rawResponse = self.cleanAIResponse(result.finalResponse)
                let (displayText, summary) = self.extractAndCleanSummary(from: rawResponse)
                let finalCost = result.totalCost

                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    self.streamingText = ""
                    self.currentToolCall = nil
                    self.messages.append(.message(
                        isUser: false,
                        text: displayText,
                        cost: finalCost,
                        summary: summary
                    ))
                }

                if let newBalance = result.newBalance {
                    self.currentBalance = newBalance
                }

                if let threadId = activeThreadId, let store = self.threadStore {
                    let currentMessages = self.messages
                    Task {
                        try? await store.saveMessages(currentMessages, toThreadId: threadId)
                        let refreshed = try? await store.loadThreads()
                        if let refreshed {
                            await MainActor.run { self.threads = refreshed }
                        }
                    }
                }

            } catch is CancellationError {
                print("[ChappieViewModel] Request cancelled by user (CancellationError)")
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    self.streamingText = ""
                    self.currentToolCall = nil
                }

            } catch ChappieError.cancelled {
                print("[ChappieViewModel] Request cancelled (URLError.cancelled)")
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    self.streamingText = ""
                    self.currentToolCall = nil
                }

            } catch {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    self.streamingText = ""
                    self.currentToolCall = nil
                    self.messages.append(.message(isUser: false, text: "Упс, ошибка: \(error.localizedDescription)"))
                }
            }

            self.isThinking = false
            self.currentRequestTask = nil
        }
    }

    /// Cancels the currently running AI request.
    /// Swift structured concurrency propagates cancellation into the orchestrator automatically.
    func cancelCurrentRequest() {
        guard let task = currentRequestTask else { return }
        print("[ChappieViewModel] Cancelling current request...")
        task.cancel()
        // isThinking and currentToolCall are reset inside the task's catch block
    }

    // MARK: - History Management

    func clearMessages() {
        messages = []
    }

    func clearHistory() {
        messages.removeAll()
        messages.append(.message(isUser: false, text: "Память очищена. Я забыл всё, что мы обсуждали до этого момента. Готов начать с чистого листа!"))

        if let threadId = activeThread?.id, let store = threadStore {
            Task {
                try? await store.saveMessages([ChatMessage](), toThreadId: threadId)
            }
        }
    }

    // MARK: - Build Network History

    private func buildRawNetworkHistory() -> [AIMessage] {
        return messages.compactMap { msg -> AIMessage? in
            guard case .message(_, let isUser, let text, _, let summary) = msg else {
                return nil
            }

            let isSystemMessage = text.contains("Проект подключен")
                || text.contains("Память очищена")
                || text.contains("API-ключ обновлён")
                || text.hasPrefix("⚠️")
                || text.hasPrefix("Ошибка:")
                || text.hasPrefix("Упс, ошибка:")

            if isSystemMessage { return nil }

            let role = isUser ? "user" : "assistant"

            if !isUser, let summary = summary {
                let textWithSummary = text + "\n<summary>\(summary)</summary>"
                return AIMessage(role: role, content: textWithSummary)
            }

            return AIMessage(role: role, content: text)
        }
    }

    // MARK: - Self-Summary Parsing

    private func extractAndCleanSummary(from text: String) -> (displayText: String, summary: String?) {
        guard let regex = try? NSRegularExpression(
            pattern: "<summary>(.*?)</summary>",
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else {
            return (text, nil)
        }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        guard let lastMatch = matches.last,
              let summaryRange = Range(lastMatch.range(at: 1), in: text),
              let fullMatchRange = Range(lastMatch.range, in: text) else {
            return (text, nil)
        }

        let summary = String(text[summaryRange]).trimmingCharacters(in: .whitespacesAndNewlines)

        var displayText = text
        displayText.removeSubrange(fullMatchRange)
        displayText = displayText.trimmingCharacters(in: .whitespacesAndNewlines)

        let finalDisplayText = displayText.isEmpty ? summary : displayText

        return (finalDisplayText, summary.isEmpty ? nil : summary)
    }

    // MARK: - Service Initialization

    private func initializeServices(for url: URL) {
        let fs = FileSystemManager(workspaceURL: url)
        self.fileSystem = fs

        let mm = MemoryManager(workspaceURL: url)
        self.memoryManager = mm

        Task {
            await mm.initializeWorkspaceMemory()
            if let store = self.memoryStore {
                await mm.setMemoryStore(store)
            }
        }

        let socketPath = MCPHelperLauncher.shared.socketPath

        let ts = ToolExecutionService(fileSystem: fs, memoryManager: mm, socketPath: socketPath)
        self.toolService = ts

        if let client = aiClient {
            self.orchestrator = AIOrchestrator(
                aiClient: client,
                toolService: ts,
                fileSystem: fs,
                memoryManager: mm
            )
        }

        if let pStore = projectStore, let tStore = threadStore {
            registerProjectToolHandlers(toolService: ts, projectStore: pStore, threadStore: tStore)
        }

        Task {
            await syncActiveMemoryContext()
        }
    }

    // MARK: - Migration (IT-04)

    private func runMigrationIfNeeded(threadStore: ThreadStore, memoryStore: MemoryStore) async {
        let migrationService = MigrationService(
            threadStore: threadStore,
            memoryStore: memoryStore
        )

        let chatHistoryURL: URL
        if let workspaceURL = workspaceURL {
            chatHistoryURL = workspaceURL.appendingPathComponent("chat_history.json")
        } else {
            chatHistoryURL = ChatHistoryManager.shared.fileURL
        }

        let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let semanticURL = docsURL
            .appendingPathComponent("Chappie")
            .appendingPathComponent("semantic.json")

        let didMigrate = await migrationService.migrate(
            messageType: ChatMessage.self,
            chatHistoryURL: chatHistoryURL,
            semanticMemoryURL: semanticURL
        )

        if didMigrate {
            print("[ChappieViewModel] Migration IT-04 completed")
        }
    }

    // MARK: - Response Cleanup

    private func cleanAIResponse(_ text: String) -> String {
        var cleanedText = text
        if let regex = try? NSRegularExpression(
            pattern: "94>thought.*?needed\\.\\n*",
            options: [.dotMatchesLineSeparators]
        ) {
            cleanedText = regex.stringByReplacingMatches(
                in: cleanedText,
                options: [],
                range: NSRange(location: 0, length: cleanedText.utf16.count),
                withTemplate: ""
            )
        }
        return cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Local Message Storage

    private func saveMessages() {
        guard !isLoadingThread else { return }
        chatHistoryManager.saveMessages(messages)
    }

    private func loadMessages() {
        let loadedMessages: [ChatMessage] = chatHistoryManager.loadMessages()

        if !loadedMessages.isEmpty {
            self.messages = loadedMessages
        } else {
            if let data = UserDefaults.standard.data(forKey: "savedChatMessages"),
               let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) {
                self.messages = decoded
                chatHistoryManager.saveMessages(self.messages)
                UserDefaults.standard.removeObject(forKey: "savedChatMessages")
            }
        }
    }

    // MARK: - Security-Scoped Bookmarks (macOS Sandbox)

    private func saveWorkspaceWithSecurityScope(_ url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: "workspaceBookmark")
        } catch {
            if let data = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                UserDefaults.standard.set(data, forKey: "workspaceBookmark")
            }
        }
    }

    private func loadWorkspaceWithSecurityScope() {
        guard let data = UserDefaults.standard.data(forKey: "workspaceBookmark") else { return }
        var isStale = false

        let secureURL = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        if let url = secureURL {
            _ = url.startAccessingSecurityScopedResource()
            self.workspaceURL = url
            initializeServices(for: url)
            chatHistoryManager = ChatHistoryManager(workspaceURL: url)
            loadMessages()
            if isStale { saveWorkspaceWithSecurityScope(url) }
            MCPHelperLauncher.shared.launch(workspacePath: url.path)

        } else {
            let fallbackURL = try? URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if let url = fallbackURL {
                self.workspaceURL = url
                initializeServices(for: url)
                chatHistoryManager = ChatHistoryManager(workspaceURL: url)
                loadMessages()
                MCPHelperLauncher.shared.launch(workspacePath: url.path)
            }
        }
    }
}
