// ChappieViewModel.swift
// Chappie
//
// Core @Observable class: state, init, service wiring, pagination, drafts, balance.
// Business logic is split into extensions:
//   +Threads, +Providers, +Projects, +Send, +Memory, +AppSettings, +ThreadSession, +License
//
// STORAGE:
// setModelContainer() wires up both backends and runs MigrationService.
// After migration, chappieDataStore points to SQLiteStorage — all Stores use it.
// ChappieDataStore (SwiftData) is only kept alive as migration source.

import SwiftUI
import ChappieCore
import SwiftData

@Observable
@MainActor
final class ChappieViewModel {

    // MARK: - Pagination constants

    let pageSize = 30
    let pageSizeLoad = 30
    // maxDisplayed applies only to appendToDisplayed (new messages arriving).
    // loadMoreMessages does NOT trim the bottom — user must scroll freely through history.
    let maxDisplayed = 60

    // MARK: - Isolated streaming state

    // Streaming properties live in StreamingState so token updates don't invalidate
    // ContentView, topPanel, or bottomPanel — only ChatScrollView and InputMorphView subscribe.
    let streaming = StreamingState()

    // MARK: - Backward-compat accessors

    var isThinking: Bool {
        get { streaming.isThinking }
        set { streaming.isThinking = newValue }
    }

    var streamingText: String {
        get { streaming.streamingText }
        set { streaming.streamingText = newValue }
    }

    var runningCost: Double {
        get { streaming.runningCost }
        set { streaming.runningCost = newValue }
    }

    // Throttled via setToolCall() — fires thinkingView animation at most 5x/sec.
    var currentToolCall: String? {
        get { streaming.currentToolCall }
        set { streaming.setToolCall(newValue) }
    }

    // Balance forwarded to/from StreamingState so ModelPickerRow re-renders in isolation.
    var currentBalance: Double? {
        get { streaming.currentBalance }
        set { streaming.currentBalance = newValue }
    }

    // MARK: - State

    var workspaceURL: URL?
    var messages: [ChatMessage] = []
    var displayedMessages: [ChatMessage] = []
    var hasMoreMessages: Bool = false
    var displayedStart: Int = 0
    var scrollToBottomTrigger: Int = 0
    var loadMoreAnchorId: UUID? = nil

    var visibleMessages: [ChatMessage] {
        let onlyMessages = messages.filter { if case .message = $0 { return true }; return false }
        if activeThreadSettings.isUnlimitedContext { return onlyMessages }
        return Array(onlyMessages.suffix(activeThreadSettings.maxMessagesInContext * 10))
    }

    var isLoadingThread: Bool = false
    // True from selectThread() start until _syncTask fully completes (messages + session ready).
    // Drives the "Загрузка" spinner in ChatScrollView — hides empty flash during thread switch.
    var isLoadingMessages: Bool = false
    var isAppReady: Bool = false
    var currentRequestTask: Task<Void, Never>? = nil
    var showNoProviderAlert: Bool = false
    var _syncTask: Task<Void, Never>? = nil
    var isFileSystemReady: Bool = true

    // MARK: - License

    /// Actor-based license service — offline JWT verification + online activation.
    let licenseService = LicenseService()

    /// Published license state — SwiftUI views observe this directly.
    var licenseState: LicenseState = .loading

    // MARK: - Threads

    var threads: [ThreadMetadata] = []
    var activeThread: ThreadMetadata? = nil
    var activeProjects: [ProjectMetadata] = []
    var activeThreadSettings: ThreadSettings = ThreadSettings()
    var activeConfig: AppConfig { AppConfig(settings: activeThreadSettings) }
    var activeMemoryContext: MemoryContext = .empty

    // MARK: - AI Providers

    var providers: [AIProvider] = []
    var activeProvider: AIProvider? = nil
    var activeKeyId: UUID? = nil
    var activeModelName: String? = nil

    var isThreadOrphaned: Bool {
        guard let provider = activeProvider else {
            return activeThreadSettings.activeProviderId != nil
        }
        guard providers.contains(where: { $0.id == provider.id }) else { return true }
        if let keyId = activeKeyId, !provider.keys.contains(where: { $0.id == keyId }) { return true }
        if let modelName = activeModelName {
            return !provider.models.contains(where: { $0.id == modelName })
        }
        return false
    }

    var showNewThreadProviderPicker: Bool = false
    var pendingNewThread: ThreadMetadata? = nil
    var threadDrafts: [UUID: String] = [:]

    // MARK: - Dependencies

    var fileSystem: FileSystemManager?
    var memoryManager: MemoryManager?
    var webFetchService: WebFetchService?
    var toolService: ToolExecutionService?
    // Protocol type — can be AIClient (OpenAI) or AnthropicClient
    var aiClient: (any AIClientProtocol)?
    var orchestrator: AIOrchestrator?

    // MARK: - Shared remote services

    /// Single shared instance — caches the catalog for the entire app session.
    let providersRemoteService = ProvidersRemoteService()

    // MARK: - Storage

    var modelContainer: ModelContainer?

    // Active storage backend — SQLiteStorage after migration, ChappieDataStore before.
    // All Stores use this reference. Never access ChappieDataStore directly after init.
    var chappieDataStore: (any ChappieStorage)?

    var memoryStore: MemoryStore?
    var threadStore: ThreadStore?
    // ProjectStore is kept for downgradeAllProjectsToAdvisor (license enforcement).
    var projectStore: ProjectStore?
    var providerStore: AIProviderStore?

    // MARK: - AppSettingsStore + caches

    var appSettingsStore: AppSettingsStore?
    var cachedBalances: [UUID: Double] = [:]
    var cachedLastActiveThreadId: UUID?
    var _activeThreadSession: ThreadSession?

    // MARK: - Project maps for MCP routing

    /// Map of project display name → DevEnvironment rawValue.
    var activeProjectEnvMap: [String: String] {
        Dictionary(
            uniqueKeysWithValues: activeProjects
                .filter { $0.settings.isProgrammingProject && $0.settings.devEnvironment != .unknown }
                .map { ($0.displayName, $0.settings.devEnvironment.rawValue) }
        )
    }

    /// Map of project display name → absolute path on disk.
    var activeProjectPathMap: [String: String] {
        Dictionary(
            uniqueKeysWithValues: activeProjects
                .compactMap { project -> (String, String)? in
                    guard let path = project.absolutePath else { return nil }
                    return (project.displayName, path)
                }
        )
    }

    // MARK: - Init

    public init() {
        // Pre-warm catalog cache at startup so CatalogPickerSheet opens instantly.
        Task {
            do {
                let catalog = try await providersRemoteService.fetchCatalog(forceRefresh: true)
                print("[ChappieViewModel] Catalog pre-loaded: \(catalog.providers.count) providers, \(catalog.meta.modelsCount) models")
            } catch {
                print("[ChappieViewModel] Catalog pre-load failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Pagination

    func resetPagination(fireScrollTrigger: Bool = false) {
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
        if fireScrollTrigger { scrollToBottomTrigger += 1 }
    }

    func loadMoreMessages() {
        guard hasMoreMessages, displayedStart > 0 else { return }
        let newStart = max(0, displayedStart - pageSizeLoad)
        let additional = Array(messages[newStart..<displayedStart])
        guard !additional.isEmpty else { return }

        loadMoreAnchorId = displayedMessages.first?.id

        displayedStart = newStart
        displayedMessages = additional + displayedMessages
        hasMoreMessages = displayedStart > 0
    }

    func appendToDisplayed(_ message: ChatMessage) {
        displayedMessages.append(message)
        // Trim oldest from the top to keep memory bounded during long active sessions.
        if displayedMessages.count > maxDisplayed {
            let excess = displayedMessages.count - maxDisplayed
            displayedMessages = Array(displayedMessages.dropFirst(excess))
            displayedStart += excess
            hasMoreMessages = displayedStart > 0
        }
    }

    // MARK: - Draft Management

    func getDraft(for threadId: UUID) -> String { threadDrafts[threadId] ?? "" }
    func setDraft(_ text: String, for threadId: UUID) { threadDrafts[threadId] = text }
    func clearDraft(for threadId: UUID) { threadDrafts.removeValue(forKey: threadId) }

    // MARK: - Balance

    func refreshBalanceForActiveProvider() {
        guard let provider = activeProvider else { return }
        self.currentBalance = loadBalance(for: provider.id)
    }

    // MARK: - Connect Storage

    /// Wires up both storage backends, runs one-time migration, then boots all Stores.
    /// Called from ChappieApp.onAppear — guaranteed to run once on main actor.
    func setModelContainer(_ container: ModelContainer) {
        guard self.modelContainer == nil else { return }
        self.modelContainer = container

        // Legacy SwiftData backend — migration source only.
        let swiftDataStore = ChappieDataStore(modelContainer: container)

        // Production SQLite backend.
        guard let sqliteURL = try? SQLiteStorage.defaultURL,
              let sqliteStore = try? SQLiteStorage(url: sqliteURL) else {
            // Fallback: if SQLite init fails (disk full, permissions) — keep SwiftData running.
            print("[ChappieViewModel] ⚠️ SQLiteStorage init failed — falling back to SwiftData")
            bootStores(with: swiftDataStore)
            return
        }

        // Run migration in background — Stores start on SQLite immediately.
        // Migration is safe to run while SQLite is already in use (upserts are idempotent).
        Task {
            let migration = MigrationService(source: swiftDataStore, target: sqliteStore)
            await migration.migrateIfNeeded()
        }

        // All Stores use SQLite from this point forward.
        bootStores(with: sqliteStore)
    }

    /// Initializes all Stores with the given backend and starts the app boot sequence.
    private func bootStores(with storage: any ChappieStorage) {
        self.chappieDataStore = storage

        let store = MemoryStore(dataStore: storage)
        self.memoryStore = store

        let tStore = ThreadStore(dataStore: storage)
        self.threadStore = tStore

        let pStore = ProjectStore(dataStore: storage, threadStore: tStore)
        self.projectStore = pStore

        let provStore = AIProviderStore(dataStore: storage)
        self.providerStore = provStore

        let settingsStore = AppSettingsStore(dataStore: storage)
        self.appSettingsStore = settingsStore

        // Initialize services immediately — even without a workspace URL.
        // WHY: orchestrator requires toolService/fileSystem/memoryManager to be non-nil.
        let placeholderURL = FileManager.default.homeDirectoryForCurrentUser
        if toolService == nil {
            initializeServices(for: placeholderURL)
        }

        if let mm = memoryManager { Task { await mm.setMemoryStore(store) } }

        print("[ChappieViewModel] Storage connected: \(type(of: storage))")

        if let ts = toolService {
            registerProjectToolHandlers(toolService: ts)
        }

        initializeLicense()

        Task {
            await preloadLastActiveThreadId()
            await refreshBalanceCacheIfNeeded()

            await loadWorkspaceFromStore(settingsStore)

            if let catalog = try? await providersRemoteService.fetchCatalog() {
                try? await provStore.syncRequiresApiKey(from: catalog.providers)
                print("[ChappieViewModel] requiresApiKey synced from catalog")
                try? await provStore.syncIcons(from: catalog.providers)
                print("[ChappieViewModel] Icons synced from catalog")
            }

            await loadProvidersAndSetActive(from: provStore)
            await loadThreadsAndSelectActive(from: tStore)
        }
    }

    // MARK: - History Management

    func clearMessages() {
        messages = []
        resetPagination(fireScrollTrigger: false)
    }

    func clearHistory() {
        messages.removeAll()
        let systemMessage = ChatMessage.message(
            isUser: false,
            text: String(localized: "system.memory_cleared")
        )
        messages.append(systemMessage)
        resetPagination(fireScrollTrigger: false)

        if let threadId = activeThread?.id, let store = threadStore {
            Task { try? await store.saveMessages([ChatMessage](), toThreadId: threadId) }
        }
    }

    // MARK: - Workspace Management

    func setWorkspace(_ url: URL) {
        workspaceURL = url
        initializeServices(for: url)
        saveWorkspaceWithSecurityScope(url)
        MCPHelperLauncher.shared.restartWithWorkspace(
            url,
            projectEnvMap: activeProjectEnvMap,
            projectPathMap: activeProjectPathMap
        )

        if messages.isEmpty {
            messages.append(.message(isUser: false, text: String(localized: "system.project_connected")))
        }
    }

    // MARK: - Service Initialization

    func initializeServices(for url: URL) {
        let fs = FileSystemManager(workspaceURL: url)
        self.fileSystem = fs

        let mm = MemoryManager(workspaceURL: url)
        self.memoryManager = mm

        Task {
            await mm.initializeWorkspaceMemory()
            if let store = self.memoryStore { await mm.setMemoryStore(store) }
        }

        let wf = WebFetchService()
        self.webFetchService = wf

        let socketPath = MCPHelperLauncher.shared.socketPath
        let ts = ToolExecutionService(fileSystem: fs, memoryManager: mm, socketPath: socketPath, webFetch: wf)
        self.toolService = ts

        if let client = aiClient {
            self.orchestrator = AIOrchestrator(aiClient: client, toolService: ts, fileSystem: fs, memoryManager: mm)
        }

        registerProjectToolHandlers(toolService: ts)
        registerAttachmentHandlers(toolService: ts)

        Task { await syncActiveMemoryContext() }
    }

    // MARK: - Attachment Handler Registration

    /// Bridges AttachmentStore (app target) into ToolExecutionService (ChappieCore target)
    /// via closures — avoids cross-target dependency.
    ///
    /// WHY local capture of AttachmentStore.shared:
    /// ChappieViewModel is @MainActor. Sendable closures passed to ToolExecutionService
    /// (an actor) cannot reference @MainActor-isolated state. We capture a local reference
    /// to AttachmentStore.shared (which is @unchecked Sendable) before entering the Task,
    /// so the closures are fully nonisolated.
    private func registerAttachmentHandlers(toolService: ToolExecutionService) {
        let store = AttachmentStore.shared
        Task {
            await toolService.registerAttachmentHandlers(
                resolve: { uuid in
                    store.resolve(uuid: uuid)
                },
                save: { data, filename in
                    let attachmentId = UUID()
                    guard let url = store.save(data: data, filename: filename, forAttachmentId: attachmentId) else {
                        return nil
                    }
                    return AttachmentSaveResult(url: url, uuid: attachmentId)
                },
                reserve: { filename, uuid in
                    store.reserveURL(filename: filename, forAttachmentId: uuid)
                }
            )
        }
    }

    // MARK: - Security-Scoped Bookmarks

    func saveWorkspaceWithSecurityScope(_ url: URL) {
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            saveWorkspaceBookmark(data)
        } catch {
            if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                saveWorkspaceBookmark(data)
            }
        }
    }

    /// Loads workspace from AppSettingsStore after store is ready.
    /// Migrates legacy UserDefaults bookmark on first run, then removes it.
    func loadWorkspaceFromStore(_ store: AppSettingsStore) async {
        guard workspaceURL == nil else { return }

        var bookmarkData: Data? = try? await store.loadWorkspaceBookmark()

        // One-time migration: if store has no bookmark but UserDefaults does — migrate and clean up.
        if bookmarkData == nil, let legacyData = UserDefaults.standard.data(forKey: "workspaceBookmark") {
            bookmarkData = legacyData
            try? await store.save(workspaceBookmark: legacyData)
            UserDefaults.standard.removeObject(forKey: "workspaceBookmark")
            print("[ChappieViewModel] Workspace bookmark migrated from UserDefaults to AppSettingsStore")
        }

        guard let data = bookmarkData else { return }

        var isStale = false
        if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
            _ = url.startAccessingSecurityScopedResource()
            await MainActor.run {
                self.workspaceURL = url
                self.initializeServices(for: url)
            }
            if isStale { saveWorkspaceWithSecurityScope(url) }
            MCPHelperLauncher.shared.launch(
                workspacePath: url.path,
                projectEnvMap: activeProjectEnvMap,
                projectPathMap: activeProjectPathMap
            )
        } else if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
            await MainActor.run {
                self.workspaceURL = url
                self.initializeServices(for: url)
            }
            MCPHelperLauncher.shared.launch(
                workspacePath: url.path,
                projectEnvMap: activeProjectEnvMap,
                projectPathMap: activeProjectPathMap
            )
        }
    }
}
