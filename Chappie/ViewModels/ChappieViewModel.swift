// ChappieViewModel.swift
// Chappie
//
// Core @Observable class: state properties, init, service wiring, pagination, drafts, balance.
// Business logic is split into extensions:
//   +Threads, +Providers, +Projects, +Send, +Memory, +AppSettings (V2), +ThreadSession (V2)

import SwiftUI
import ChappieCore
import SwiftData

@Observable
@MainActor
final class ChappieViewModel {

    // MARK: - Pagination constants

    /// Number of messages shown on initial thread load.
    let pageSize = 50

    /// Number of messages prepended when user loads more (scrolls to top).
    let pageSizeLoad = 30

    // MARK: - State

    var workspaceURL: URL?
    var messages: [ChatMessage] = []

    /// Paginated slice shown in ChatScrollView.
    var displayedMessages: [ChatMessage] = []

    /// True when older messages exist above the current displayed slice.
    var hasMoreMessages: Bool = false

    /// Index into `messages` marking the start of the current displayed slice.
    var displayedStart: Int = 0

    /// Incremented to trigger scroll-to-bottom in ChatScrollView.
    var scrollToBottomTrigger: Int = 0

    /// Messages passed to the network context window (excludes system messages).
    var visibleMessages: [ChatMessage] {
        let onlyMessages = messages.filter { if case .message = $0 { return true }; return false }
        if activeThreadSettings.isUnlimitedContext { return onlyMessages }
        return Array(onlyMessages.suffix(activeThreadSettings.maxMessagesInContext * 10))
    }

    var isThinking = false
    var streamingText: String = ""
    var runningCost: Double = 0.0
    var currentToolCall: String? = nil
    var currentBalance: Double?

    var isLoadingThread: Bool = false
    var isAppReady: Bool = false

    var currentRequestTask: Task<Void, Never>? = nil

    // MARK: - Threads

    var threads: [ThreadMetadata] = []
    var activeThread: ThreadMetadata? = nil

    // MARK: - Projects in thread

    var activeProjects: [ProjectMetadata] = []

    // MARK: - Active thread settings

    var activeThreadSettings: ThreadSettings = ThreadSettings()

    var activeConfig: AppConfig { AppConfig(settings: activeThreadSettings) }

    // MARK: - Memory context for system prompt

    var activeMemoryContext: MemoryContext = .empty

    // MARK: - AI Providers

    var providers: [AIProvider] = []
    var activeProvider: AIProvider? = nil
    var activeModelName: String? = nil

    var isThreadOrphaned: Bool {
        guard let provider = activeProvider else {
            return activeThreadSettings.activeProviderId != nil
        }
        guard providers.contains(where: { $0.id == provider.id }) else { return true }
        if let model = activeModelName { return !provider.models.contains(model) }
        return false
    }

    var showNewThreadProviderPicker: Bool = false
    var pendingNewThread: ThreadMetadata? = nil

    // MARK: - Draft per thread

    var threadDrafts: [UUID: String] = [:]

    // MARK: - Dependencies

    var fileSystem: FileSystemManager?
    var memoryManager: MemoryManager?
    var webFetchService: WebFetchService?
    var toolService: ToolExecutionService?
    var aiClient: AIClient?
    var orchestrator: AIOrchestrator?

    // MARK: - SwiftData

    var modelContainer: ModelContainer?
    var memoryStore: MemoryStore?
    var threadStore: ThreadStore?
    var projectStore: ProjectStore?
    var providerStore: AIProviderStore?

    // MARK: - V2: AppSettingsStore + caches

    /// V2 SwiftData-backed settings store. Nil when flag is OFF.
    var appSettingsStore: New.AppSettingsStore?

    /// In-memory cache for provider balances (V2 path).
    /// Populated by refreshBalanceCacheIfNeeded() on startup.
    var cachedBalances: [UUID: Double] = [:]

    /// In-memory cache for last active thread ID (V2 path).
    /// Populated by preloadLastActiveThreadId() before thread selection.
    var cachedLastActiveThreadId: UUID?

    // MARK: - V2: ThreadSession (backing storage for computed var in +ThreadSession extension)

    /// Backing store for activeThreadSession. Use the computed var from +ThreadSession.
    var _activeThreadSession: New.ThreadSession?

    // MARK: - UserDefaults keys (legacy — kept for V1 path and migration)

    let lastActiveThreadIdKey = "lastActiveThreadId"

    // MARK: - Init

    public init() {
        loadWorkspaceWithSecurityScope()
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
        displayedStart = newStart
        displayedMessages = additional + displayedMessages
        hasMoreMessages = displayedStart > 0
    }

    func appendToDisplayed(_ message: ChatMessage) {
        displayedMessages.append(message)
    }

    // MARK: - Draft Management

    func getDraft(for threadId: UUID) -> String { threadDrafts[threadId] ?? "" }
    func setDraft(_ text: String, for threadId: UUID) { threadDrafts[threadId] = text }
    func clearDraft(for threadId: UUID) { threadDrafts.removeValue(forKey: threadId) }

    // MARK: - Balance key (legacy path only)

    func balanceKey(for providerId: UUID) -> String { "balance_\(providerId.uuidString)" }

    func refreshBalanceForActiveProvider() {
        guard let provider = activeProvider else { return }
        self.currentBalance = loadBalance(for: provider.id)
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

        // V2: wire AppSettingsStore when flag is active
        connectAppSettingsStore(container: container)

        if let mm = memoryManager { Task { await mm.setMemoryStore(store) } }

        print("[ChappieViewModel] ModelContainer connected")

        if let ts = toolService {
            registerProjectToolHandlers(toolService: ts, projectStore: pStore, threadStore: tStore)
        }

        Task {
            // V2: preload caches before thread selection so loadLastActiveThreadId() works synchronously
            await preloadLastActiveThreadId()
            await refreshBalanceCacheIfNeeded()

            await runMigrationIfNeeded(threadStore: tStore, memoryStore: store)
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
        let systemMessage = ChatMessage.message(isUser: false, text: "Память очищена. Я забыл всё, что мы обсуждали до этого момента. Готов начать с чистого листа!")
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
        MCPHelperLauncher.shared.restartWithWorkspace(url)

        if messages.isEmpty {
            messages.append(.message(isUser: false, text: "Проект подключен. Я готов к работе!"))
        }
    }

    // MARK: - Migration

    func runMigrationIfNeeded(threadStore: ThreadStore, memoryStore: MemoryStore) async {
        let migrationService = MigrationService(threadStore: threadStore, memoryStore: memoryStore)

        let chatHistoryURL: URL
        if let workspaceURL = workspaceURL {
            chatHistoryURL = workspaceURL.appendingPathComponent("chat_history.json")
        } else {
            chatHistoryURL = ChatHistoryManager.shared.fileURL
        }

        let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let semanticURL = docsURL.appendingPathComponent("Chappie").appendingPathComponent("semantic.json")

        let didMigrate = await migrationService.migrate(
            messageType: ChatMessage.self,
            chatHistoryURL: chatHistoryURL,
            semanticMemoryURL: semanticURL
        )
        if didMigrate { print("[ChappieViewModel] Migration IT-04 completed") }
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

        if let pStore = projectStore, let tStore = threadStore {
            registerProjectToolHandlers(toolService: ts, projectStore: pStore, threadStore: tStore)
        }

        Task { await syncActiveMemoryContext() }
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

    func loadWorkspaceWithSecurityScope() {
        // Workspace loading at init time happens synchronously — V2 store isn't ready yet.
        // We always read from UserDefaults here; V2 store is wired later in setModelContainer.
        // WHY: ModelContainer is injected via setModelContainer() after init completes.
        // The async V2 path (loadWorkspaceBookmarkData) is used for subsequent restores.
        guard let data = UserDefaults.standard.data(forKey: "workspaceBookmark") else { return }
        var isStale = false

        if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
            _ = url.startAccessingSecurityScopedResource()
            self.workspaceURL = url
            initializeServices(for: url)
            if isStale { saveWorkspaceWithSecurityScope(url) }
            MCPHelperLauncher.shared.launch(workspacePath: url.path)
        } else if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
            self.workspaceURL = url
            initializeServices(for: url)
            MCPHelperLauncher.shared.launch(workspacePath: url.path)
        }
    }
}
