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
// CANCEL STATE FIX: catch blocks for CancellationError/ChappieError.cancelled wrap
// state resets in Task { @MainActor in } to guarantee UI updates on the main thread.
// Without this, withAnimation{} called from a background thread is silently ignored
// by SwiftUI — isThinking stays true and the input panel never morphs back to idle.
//
// LIVE BALANCE (UX-BALANCE-LIVE):
// onBalanceUpdate callback passed to orchestrator.process() — fires after each streaming
// step that returns a balance. Updates currentBalance in real time so the balance pill
// in ModelPickerRow ticks down visibly during the response.
//
// BALANCE STORAGE (UX-BALANCE-PER-PROVIDER):
// Balance is stored per provider in UserDefaults under key "balance_<provider.id>".
// On switchProvider — the stored balance for the new provider is loaded.
// On balance update — saved under the active provider's key.
// This ensures each endpoint shows its own balance, not a shared global value.
//
// BALANCE ON STARTUP (UX-BALANCE-STARTUP):
// selectThread() always calls refreshBalanceForActiveProvider() at the end,
// regardless of which code path was taken. This guarantees the pill is visible
// after app launch even if switchProvider() was not called during thread selection.
//
// MODEL BUG FIX (MODEL-PER-THREAD):
// selectThread() ALWAYS calls switchProvider() — even when activeProvider is already set.
// If the thread has no saved provider, the default provider is used.
// This ensures activeProvider/activeModelName always reflect the SELECTED THREAD,
// not the previously active one.
//
// INPUT PANEL BUG FIX (THINKING-STUCK):
// isThinking = false is set INSIDE withAnimation{} in the success path,
// so SwiftUI applies it atomically with streamingText = "" and messages.append().
// The background save Task is explicitly @MainActor to avoid race conditions
// with @Observable property updates.
//
// DRAFT PER THREAD (UX-DRAFT):
// threadDrafts: [UUID: String] stores unsent input text per thread.
// When user switches threads, the draft for the old thread is preserved.
// When user returns — the draft is restored. Cleared on send.
// ContentView reads/writes draft via getDraft()/setDraft()/clearDraft().
//
// LAST ACTIVE THREAD (UX-RESTORE):
// The last active thread ID is saved to UserDefaults on every selectThread() call.
// On startup, loadThreadsAndSelectActive() restores it instead of defaulting to [0].
// Key: "lastActiveThreadId" (UUID string).
//
// THREAD SETTINGS (IT-11):
// updateThreadSettings(_:title:forThreadId:) — saves both title and ThreadSettings.
// Called from ContentView when user saves ThreadSettingsSheet.
// ThreadMetadata now includes settings field — no extra store call needed in UI.
//
// NEW THREAD FLOW (IT-12):
// confirmNewThread(with:modelName:title:settings:) — extended signature.
// Saves title via renameThread and context settings via updateSettings immediately
// after thread creation, before selectThread() is called.
//
// PAGINATION (UX-PAGINATION):
// displayedMessages — the slice of messages shown in ChatScrollView.
// On thread load: initialized to the last PAGE_SIZE messages.
// loadMoreMessages() — prepends the previous PAGE_SIZE_LOAD messages.
// hasMoreMessages — true when there are older messages not yet displayed.
// resetPagination(fireScrollTrigger:) — called on every thread switch.
// visibleMessages is UNCHANGED — it is used for network context, not UI rendering.
// This replaces LazyVStack with a plain VStack in ChatScrollView, eliminating
// the disappearing-messages bug caused by lazy cell recycling.
//
// SCROLL TRIGGER FIX v3 (UX-SCROLL-TRIGGER-V3):
// Root cause of "bad range for [%{public}s]":
//   The old resetPagination() always incremented scrollToBottomTrigger.
//   So on first render scrollToBottomTrigger was already 1 — .task(id:) fired
//   immediately, but ScrollView had no layout geometry yet → "bad range".
//
// Fix: resetPagination(fireScrollTrigger: Bool).
//   fireScrollTrigger=false — only updates displayedMessages/hasMoreMessages/displayedStart.
//     Used by: clearMessages(), clearHistory(), confirmNewThread().
//   fireScrollTrigger=true — also increments scrollToBottomTrigger.
//     Used ONLY by: selectThread() — the only caller that has a live view tree.
//
// This guarantees scrollToBottomTrigger stays 0 until selectThread() is called
// from setModelContainer() AFTER the view is on screen. The .task(id: 0) guard
// (guard scrollToBottomTrigger > 0) remains as a second safety net.
//
// CHAT HISTORY STORAGE (IT-13):
// Messages are stored per-thread in SwiftData via ThreadStore.
// ChatHistoryManager (file-based) has been removed.
// selectThread() loads messages via store.loadMessages().
// send() saves messages via store.saveMessages() after each response.
// clearHistory() saves an empty array to the thread's SwiftData record.
//
// LOADING HISTORY INDICATOR (UX-LOADING):
// isLoadingThread is exposed as private(set) so ChatScrollView can show a ProgressView
// while history is being loaded from SwiftData. This prevents the welcome screen flash
// that occurred when the app started and the history was not yet available.
//
// LOADING HISTORY FIX (UX-LOADING-FIX):
// isLoadingThread = true and messages = [] are set at the very beginning of selectThread(),
// BEFORE activeThread is assigned. This guarantees that SwiftUI never renders a frame
// with isLoadingThread=false + messages=[] simultaneously (which caused the welcome
// screen flash). The spinner is always shown during the async load window.
//
// APP READY FLAG (UX-APP-READY):
// isAppReady starts as false and becomes true only when the very first selectThread()
// completes. ContentView shows a ProgressView until isAppReady == true — this replaces
// the old isReady flag with its 300ms arbitrary timer.
// WHY THIS FIXES THE FLASH:
//   Old approach: isReady=true after 300ms timer → isLoadingThread may already be false
//   by then → SwiftUI sees (isLoadingThread=false, messages=[]) → welcome screen flashes.
//   New approach: isAppReady and isLoadingThread=false are set in the SAME selectThread()
//   call → SwiftUI never sees a frame where the app is "ready" but history isn't loaded.
//
// MULTIMODAL (MULTIMODAL-STEP1):
// ChatMessage.message case gained a 6th field `attachments: [AttachedFile]`.
//
// MULTIMODAL (MULTIMODAL-STEP2):
// send(prompt:attachments:) now accepts [AttachedFile].
// User message is stored with attachments in ChatMessage.message.
//
// MULTIMODAL (MULTIMODAL-STEP3):
// buildRawNetworkHistory() returns history EXCLUDING the last user message.
// The last user message is built separately as AIMessage and passed to
// orchestrator.process(currentMessage:) — preserving multimodal content.
//
// MULTIMODAL ENCODING STRATEGY:
//   Images → AIMultimodalPart.imageURL (base64 data URI, OpenAI vision format)
//   PDF/TXT → AIMultimodalPart.text (filename header + decoded text content)
//   Other binary → AIMultimodalPart.text (filename header + size note)
// Plain text messages are still encoded as AIMessage(role:content:String) — no change.
// Error handling: if the model rejects the content type, the API error is surfaced
// as a human-friendly message by ChappieViewModel's error handler in send().
//
// WEB FETCH TOOL:
// WebFetchService is created in initializeServices() alongside other services.
// It is passed to ToolExecutionService via the webFetch: parameter.
// No additional wiring needed — ToolExecutionService handles the web_fetch tool internally.

import SwiftUI
import ChappieCore
import SwiftData

@Observable
@MainActor
final class ChappieViewModel {

    // MARK: - Pagination constants

    /// Number of messages shown on initial thread load.
    private let pageSize = 50

    /// Number of messages prepended when user loads more (scrolls to top).
    private let pageSizeLoad = 30

    // MARK: - State

    var workspaceURL: URL?

    var messages: [ChatMessage] = []

    /// Messages visible in the chat scroll view — paginated slice for UI rendering.
    private(set) var displayedMessages: [ChatMessage] = []

    /// True when there are older messages above the current displayedMessages slice.
    private(set) var hasMoreMessages: Bool = false

    /// Index into `messages` marking the start of the current displayed slice.
    private var displayedStart: Int = 0

    /// Scroll-to-bottom trigger for ChatScrollView.
    private(set) var scrollToBottomTrigger: Int = 0

    /// Messages visible in the chat scroll view (for context window building).
    var visibleMessages: [ChatMessage] {
        let onlyMessages = messages.filter { msg in
            if case .message = msg { return true }
            return false
        }
        if activeThreadSettings.isUnlimitedContext {
            return onlyMessages
        }
        let chatDepth = activeThreadSettings.maxMessagesInContext * 10
        return Array(onlyMessages.suffix(chatDepth))
    }

    var isThinking = false
    var streamingText: String = ""
    var runningCost: Double = 0.0
    var currentToolCall: String? = nil
    var currentBalance: Double?

    private(set) var isLoadingThread: Bool = false
    private(set) var isAppReady: Bool = false

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

    var providers: [AIProvider] = []
    var activeProvider: AIProvider? = nil
    var activeModelName: String? = nil

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

    var showNewThreadProviderPicker: Bool = false
    var pendingNewThread: ThreadMetadata? = nil

    // MARK: - Draft per thread (UX-DRAFT)

    private var threadDrafts: [UUID: String] = [:]

    // MARK: - Dependencies

    private var fileSystem: FileSystemManager?
    private var memoryManager: MemoryManager?
    private var webFetchService: WebFetchService?
    private var toolService: ToolExecutionService?

    private var aiClient: AIClient?
    private var orchestrator: AIOrchestrator?

    // MARK: - SwiftData

    private var modelContainer: ModelContainer?
    private var memoryStore: MemoryStore?
    private var threadStore: ThreadStore?
    private var projectStore: ProjectStore?
    var providerStore: AIProviderStore?

    // MARK: - UserDefaults keys

    private let lastActiveThreadIdKey = "lastActiveThreadId"

    // MARK: - Init

    public init() {
        loadWorkspaceWithSecurityScope()
    }

    // MARK: - Pagination (UX-PAGINATION)

    private func resetPagination(fireScrollTrigger: Bool = false) {
        let count = messages.count
        if count <= pageSize {
            displayedStart = 0
            displayedMessages = messages
            hasMoreMessages = false
        } else {
            displayedStart = count - pageSize
            displayedMessages = Array(messages[displayedStart...])
            hasMoreMessages = true
        }
        if fireScrollTrigger {
            scrollToBottomTrigger += 1
        }
    }

    func loadMoreMessages() {
        guard hasMoreMessages, displayedStart > 0 else { return }
        let newStart = max(0, displayedStart - pageSizeLoad)
        let additionalMessages = Array(messages[newStart..<displayedStart])
        displayedStart = newStart
        displayedMessages = additionalMessages + displayedMessages
        hasMoreMessages = displayedStart > 0
    }

    private func appendToDisplayed(_ message: ChatMessage) {
        displayedMessages.append(message)
    }

    // MARK: - Draft Management (UX-DRAFT)

    func getDraft(for threadId: UUID) -> String {
        threadDrafts[threadId] ?? ""
    }

    func setDraft(_ text: String, for threadId: UUID) {
        threadDrafts[threadId] = text
    }

    func clearDraft(for threadId: UUID) {
        threadDrafts.removeValue(forKey: threadId)
    }

    // MARK: - Balance Storage (per-provider)

    private func balanceKey(for providerId: UUID) -> String {
        "balance_\(providerId.uuidString)"
    }

    private func saveBalance(_ balance: Double, for providerId: UUID) {
        UserDefaults.standard.set(balance, forKey: balanceKey(for: providerId))
    }

    private func loadBalance(for providerId: UUID) -> Double? {
        let key = balanceKey(for: providerId)
        return UserDefaults.standard.object(forKey: key) as? Double
    }

    private func refreshBalanceForActiveProvider() {
        guard let provider = activeProvider else { return }
        self.currentBalance = loadBalance(for: provider.id)
    }

    // MARK: - Last Active Thread (UX-RESTORE)

    private func saveLastActiveThreadId(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: lastActiveThreadIdKey)
    }

    private func loadLastActiveThreadId() -> UUID? {
        guard let str = UserDefaults.standard.string(forKey: lastActiveThreadIdKey) else { return nil }
        return UUID(uuidString: str)
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

    func loadUserName() async -> String? {
        guard let store = memoryStore else { return nil }
        do {
            guard let json = try await store.readEntry(key: "user_name", scope: "global") else {
                return nil
            }
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

    private func loadProvidersAndSetActive(from store: AIProviderStore) async {
        do {
            let loaded = try await store.loadProviders()
            self.providers = loaded
            print("[ChappieViewModel] Loaded \(loaded.count) providers")
        } catch {
            print("[ChappieViewModel] Failed to load providers: \(error)")
        }
    }

    func switchProvider(_ provider: AIProvider, modelName: String?, from store: AIProviderStore? = nil) async {
        let provStore = store ?? self.providerStore
        guard let provStore else { return }

        let apiKey = await provStore.loadApiKey(for: provider.id) ?? ""
        let model = modelName ?? provider.models.first ?? ""
        let client = AIClient(endpoint: provider.endpoint, apiKey: apiKey, modelName: model)
        self.aiClient = client
        self.activeProvider = provider
        self.activeModelName = model.isEmpty ? nil : model

        self.currentBalance = loadBalance(for: provider.id)

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

    func switchProvider(id: UUID) {
        guard let provider = providers.first(where: { $0.id == id }),
              let provStore = providerStore else { return }
        let model = provider.models.first
        Task {
            await switchProvider(provider, modelName: model, from: provStore)
        }
    }

    func switchModel(to modelName: String) {
        guard let provider = activeProvider,
              let provStore = providerStore else { return }
        Task {
            await switchProvider(provider, modelName: modelName, from: provStore)
        }
    }

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
            } else {
                if let lastId = loadLastActiveThreadId(),
                   let lastThread = loaded.first(where: { $0.id == lastId }) {
                    await selectThread(lastThread)
                } else if let current = activeThread,
                          let updated = loaded.first(where: { $0.id == current.id }) {
                    self.activeThread = updated
                    buildAndSyncMemoryContext()
                } else {
                    await selectThread(loaded[0])
                }
            }
        } catch {
            print("[ChappieViewModel] Error loading threads: \(error)")
        }
    }

    func selectThread(_ thread: ThreadMetadata) async {
        guard let store = threadStore else { return }

        self.isLoadingThread = true
        self.messages = []
        self.displayedMessages = []

        self.activeThread = thread

        saveLastActiveThreadId(thread.id)

        do {
            let settings = try await store.loadSettings(forThreadId: thread.id)
            self.activeThreadSettings = settings

            if let providerId = settings.activeProviderId,
               let provider = providers.first(where: { $0.id == providerId }) {
                await switchProvider(provider, modelName: settings.activeModelName)
            } else if let provStore = providerStore,
                      let defaultProvider = try? await provStore.loadDefaultProvider() {
                let modelName = settings.activeModelName.flatMap { name in
                    defaultProvider.models.contains(name) ? name : nil
                } ?? defaultProvider.models.first
                await switchProvider(defaultProvider, modelName: modelName, from: provStore)
            }

            let loaded = try await store.loadMessages(
                fromThreadId: thread.id,
                as: ChatMessage.self
            )

            self.messages = loaded
            resetPagination(fireScrollTrigger: true)

            print("[ChappieViewModel] Thread '\(thread.title)' selected (\(loaded.count) messages)")
        } catch {
            print("[ChappieViewModel] Error loading thread '\(thread.title)': \(error)")
        }

        self.isLoadingThread = false
        self.isAppReady = true

        await loadProjectsForThread(thread)
        buildAndSyncMemoryContext()
        await syncActiveMemoryContext()

        refreshBalanceForActiveProvider()
    }

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
                        self.messages = []
                        resetPagination(fireScrollTrigger: false)
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

    func confirmNewThread(with providerId: UUID, modelName: String, title: String, settings: ThreadSettings) async {
        guard let thread = pendingNewThread,
              let store = threadStore else { return }
        self.pendingNewThread = nil
        self.showNewThreadProviderPicker = false

        if let provider = providers.first(where: { $0.id == providerId }) {
            await switchProvider(provider, modelName: modelName)
        }

        let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalTitle.isEmpty && finalTitle != "Новый тред" {
            try? await store.renameThread(id: thread.id, title: finalTitle)
        }

        var updatedSettings = settings
        updatedSettings.activeProviderId = providerId
        updatedSettings.activeModelName = modelName.isEmpty ? nil : modelName
        try? await store.updateSettings(updatedSettings, forThreadId: thread.id)

        if let refreshed = try? await store.loadThreads() {
            self.threads = refreshed
        }

        await selectThread(thread)
        self.messages = []
        resetPagination(fireScrollTrigger: false)
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

        threadDrafts.removeValue(forKey: thread.id)

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

    // MARK: - IT-11: Thread Settings Update

    func updateThreadSettings(_ settings: ThreadSettings, newTitle: String, forThreadId threadId: UUID) {
        guard let store = threadStore else { return }

        Task {
            do {
                try await store.renameThread(id: threadId, title: newTitle)

                var updatedSettings = settings
                if let currentProviderId = activeThreadSettings.activeProviderId {
                    updatedSettings.activeProviderId = currentProviderId
                }
                if let currentModelName = activeThreadSettings.activeModelName {
                    updatedSettings.activeModelName = currentModelName
                }
                try await store.updateSettings(updatedSettings, forThreadId: threadId)

                let refreshed = try await store.loadThreads()
                self.threads = refreshed

                if activeThread?.id == threadId,
                   let updated = refreshed.first(where: { $0.id == threadId }) {
                    self.activeThread = updated
                    self.activeThreadSettings = updatedSettings
                }

                print("[ChappieViewModel] Thread settings saved for '\(newTitle)'")
            } catch {
                print("[ChappieViewModel] Error updating thread settings: \(error)")
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
        saveWorkspaceWithSecurityScope(url)
        MCPHelperLauncher.shared.restartWithWorkspace(url)

        if messages.isEmpty {
            messages.append(.message(isUser: false, text: "Проект подключен. Я готов к работе!"))
        }
    }

    // MARK: - Send & Cancel

    /// Sends a prompt (and optional file attachments) to the orchestrator.
    ///
    /// MULTIMODAL-STEP3 ARCHITECTURE:
    /// 1. User message is stored in messages[] with attachments (for UI and persistence).
    /// 2. buildRawNetworkHistory() returns HISTORY ONLY — excludes the last user message
    ///    (the one just appended). This is the "completed pairs" history.
    /// 3. The current user turn is built as an AIMessage (possibly multimodal) and passed
    ///    to orchestrator.process(currentMessage:) separately.
    /// 4. AIOrchestrator appends currentMessage to the context window as the final user turn.
    ///
    /// WHY THIS APPROACH:
    /// The old approach passed the full messages[] (including the new user message) as history,
    /// then relied on string deduplication in buildContextWindow(). This broke for multimodal
    /// messages because their contentString is nil — dedup never triggered, causing double-send.
    /// The new approach cleanly separates "history" from "current turn".
    func send(prompt: String, attachments: [AttachedFile] = []) {
        guard !prompt.isEmpty || !attachments.isEmpty else { return }
        guard let orchestrator = orchestrator else {
            messages.append(.message(isUser: false, text: "Ошибка: Оркестратор не инициализирован. Подключите папку с проектом."))
            return
        }

        guard activeProvider != nil else {
            messages.append(.message(isUser: false, text: "⚠️ Нет настроенного AI-провайдера. Откройте настройки и добавьте провайдера."))
            return
        }

        // Store user message with attachments — displayed immediately in chat
        let userMessage = ChatMessage.message(isUser: true, text: prompt, attachments: attachments)
        messages.append(userMessage)
        appendToDisplayed(userMessage)

        isThinking = true
        streamingText = ""
        currentToolCall = nil
        runningCost = 0.0

        // Build history BEFORE the new user message (exclude it — it's the current turn).
        // buildRawNetworkHistory() now takes a count to exclude the last N messages.
        let networkHistory = buildRawNetworkHistory(excludingLast: 1)

        // Build the current turn as an AIMessage (multimodal if attachments present).
        let currentAIMessage = buildCurrentAIMessage(text: prompt, attachments: attachments)

        let config = activeConfig
        let memoryContext = activeMemoryContext
        let activeThreadId = activeThread?.id
        let activeProviderId = activeProvider?.id

        currentRequestTask = Task {
            do {
                let result = try await orchestrator.process(
                    prompt: prompt,
                    history: networkHistory,
                    currentMessage: currentAIMessage,
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
                    },
                    onBalanceUpdate: { newBalance in
                        Task { @MainActor in
                            self.currentBalance = newBalance
                            if let pid = activeProviderId {
                                self.saveBalance(newBalance, for: pid)
                            }
                        }
                    }
                )

                let rawResponse = self.cleanAIResponse(result.finalResponse)
                let (displayText, summary) = self.extractAndCleanSummary(from: rawResponse)
                let finalCost = result.totalCost

                let aiMessage = ChatMessage.message(
                    isUser: false,
                    text: displayText,
                    cost: finalCost,
                    summary: summary
                )

                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    self.streamingText = ""
                    self.currentToolCall = nil
                    self.isThinking = false
                    self.messages.append(aiMessage)
                    self.appendToDisplayed(aiMessage)
                }

                if let newBalance = result.newBalance {
                    self.currentBalance = newBalance
                    if let pid = activeProviderId {
                        self.saveBalance(newBalance, for: pid)
                    }
                }

                if let threadId = activeThreadId, let store = self.threadStore {
                    let currentMessages = self.messages
                    Task { @MainActor in
                        try? await store.saveMessages(currentMessages, toThreadId: threadId)
                        let refreshed = try? await store.loadThreads()
                        if let refreshed { self.threads = refreshed }
                    }
                }

            } catch is CancellationError {
                // CANCEL STATE FIX: must dispatch to MainActor explicitly.
                // currentRequestTask runs in an unstructured Task (no @MainActor isolation),
                // so catch blocks execute on a background thread. withAnimation{} called
                // from a background thread is silently ignored by SwiftUI — isThinking
                // stays true and InputMorphView never morphs back to the idle state.
                print("[ChappieViewModel] Request cancelled by user (CancellationError)")
                Task { @MainActor in
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                        self.streamingText = ""
                        self.currentToolCall = nil
                        self.isThinking = false
                    }
                }

            } catch ChappieError.cancelled {
                print("[ChappieViewModel] Request cancelled (URLError.cancelled)")
                Task { @MainActor in
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                        self.streamingText = ""
                        self.currentToolCall = nil
                        self.isThinking = false
                    }
                }

            } catch {
                Task { @MainActor in
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                        self.streamingText = ""
                        self.currentToolCall = nil
                        self.isThinking = false
                        let errMessage = ChatMessage.message(isUser: false, text: "Упс, ошибка: \(error.localizedDescription)")
                        self.messages.append(errMessage)
                        self.appendToDisplayed(errMessage)
                    }
                }
            }

            self.currentRequestTask = nil
        }
    }

    func cancelCurrentRequest() {
        guard let task = currentRequestTask else { return }
        print("[ChappieViewModel] Cancelling current request...")
        task.cancel()
    }

    // MARK: - History Management

    func clearMessages() {
        messages = []
        resetPagination(fireScrollTrigger: false)
    }

    func clearHistory() {
        messages.removeAll()
        let systemMessage = ChatMessage.message(isUser: false, text: "Память очищена. Я забыл всё, что мы обсуждали до этого момента. Готов начать с чистого листа!")
        messages.append(systemMessage)
        resetPagination(fireScrollTrigger: false)

        if let threadId = activeThread?.id, let store = threadStore {
            Task {
                try? await store.saveMessages([ChatMessage](), toThreadId: threadId)
            }
        }
    }

    // MARK: - Build Network History

    /// Builds the AIMessage history array for the orchestrator.
    ///
    /// MULTIMODAL-STEP3:
    /// The `excludingLast` parameter allows excluding the N most recent messages.
    /// In send(), we pass excludingLast: 1 to exclude the user message just appended —
    /// it is passed separately as currentMessage to orchestrator.process().
    ///
    /// For historical user messages with attachments, encodes them as multimodal content
    /// (OpenAI vision format) so the model can reference them in follow-up turns.
    private func buildRawNetworkHistory(excludingLast: Int = 0) -> [AIMessage] {
        // Determine the slice of messages to process
        let sourceMessages = excludingLast > 0 && messages.count > excludingLast
            ? Array(messages.dropLast(excludingLast))
            : messages

        return sourceMessages.compactMap { msg -> AIMessage? in
            guard case .message(_, let isUser, let text, _, let summary, let attachments) = msg else {
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

            // Assistant messages are always plain text (possibly with summary substitution)
            if !isUser {
                if let summary = summary {
                    let textWithSummary = text + "\n<summary>\(summary)</summary>"
                    return AIMessage(role: role, content: textWithSummary)
                }
                return AIMessage(role: role, content: text)
            }

            // User messages: encode as multimodal if attachments are present
            if !attachments.isEmpty {
                var parts: [AIMultimodalPart] = []
                if !text.isEmpty {
                    parts.append(.text(text))
                }
                for attachment in attachments {
                    parts.append(multimodalPart(for: attachment))
                }
                return AIMessage(role: role, multimodalParts: parts)
            }

            // Plain text user message — standard encoding
            return AIMessage(role: role, content: text)
        }
    }

    /// Builds the AIMessage for the current user turn.
    ///
    /// MULTIMODAL-STEP3:
    /// When attachments are present, returns a multimodal AIMessage with image/file parts.
    /// For plain text messages, returns a standard text AIMessage.
    /// This message is passed to orchestrator.process(currentMessage:) and appended
    /// as the final user turn in the context window.
    private func buildCurrentAIMessage(text: String, attachments: [AttachedFile]) -> AIMessage {
        guard !attachments.isEmpty else {
            // Plain text — standard message
            return AIMessage(role: "user", content: text)
        }

        // Build multimodal parts
        var parts: [AIMultimodalPart] = []
        if !text.isEmpty {
            parts.append(.text(text))
        }
        for attachment in attachments {
            parts.append(multimodalPart(for: attachment))
        }
        return AIMessage(role: "user", multimodalParts: parts)
    }

    /// Converts an AttachedFile into the appropriate AIMultimodalPart for the API.
    ///
    /// ENCODING RULES:
    ///   Images → base64 data URI (OpenAI vision format)
    ///   PDF    → attempt UTF-8 text extraction; fall back to size note if binary
    ///   TXT    → UTF-8 string content with filename header
    ///   Other  → filename + size note (let the model decide what to do)
    private func multimodalPart(for attachment: AttachedFile) -> AIMultimodalPart {
        switch attachment.mimeType {
        case .imageJpeg, .imagePng, .imageGif, .imageWebp:
            // Images are sent as base64 data URIs — standard OpenAI vision format
            return .imageURL(attachment.dataURI)

        case .plainText:
            // Text files: decode as UTF-8 and send content inline
            let content = String(data: attachment.data, encoding: .utf8)
                ?? String(data: attachment.data, encoding: .isoLatin1)
                ?? "[Could not decode text content]"
            return .text("File: \(attachment.filename)\n\n\(content)")

        case .pdf:
            // PDFs: attempt UTF-8 extraction (works for text-layer PDFs)
            // Real PDF parsing (PDFKit) is a future enhancement
            if let text = String(data: attachment.data, encoding: .utf8), !text.isEmpty {
                return .text("File: \(attachment.filename)\n\n\(text)")
            }
            let sizeKB = attachment.data.count / 1024
            return .text("File: \(attachment.filename) (PDF, \(sizeKB)KB) — binary content, cannot extract text inline.")

        case .other:
            // Unknown format: send filename and size; let the model handle it
            let sizeKB = attachment.data.count / 1024
            return .text("File: \(attachment.filename) (\(attachment.mimeType.rawValue), \(sizeKB)KB)")
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

        // WebFetchService — created once per workspace, shared with ToolExecutionService
        let wf = WebFetchService()
        self.webFetchService = wf

        let socketPath = MCPHelperLauncher.shared.socketPath

        // Pass WebFetchService into ToolExecutionService via DI
        let ts = ToolExecutionService(fileSystem: fs, memoryManager: mm, socketPath: socketPath, webFetch: wf)
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
                MCPHelperLauncher.shared.launch(workspacePath: url.path)
            }
        }
    }
}
