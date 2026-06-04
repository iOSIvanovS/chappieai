// ChappieViewModel.swift
// Chappie
//
// Core @Observable class: state properties, init, service wiring, pagination, drafts, balance.
// Business logic is split into extensions:
//   +Threads, +Providers, +Projects, +Send, +Memory, +AppSettings, +ThreadSession
//
// CPU-13: STREAMING ISOLATION
// streamingText, runningCost, currentToolCall, isThinking are moved into a
// dedicated StreamingState object. ContentView passes `streaming` as a `let`
// reference without reading any of its properties — so token updates no longer
// invalidate ContentView, topPanel, or bottomPanel. Only ChatScrollView and
// InputMorphView subscribe to StreamingState directly.
//
// CPU-15: currentBalance MOVED TO StreamingState.
// Was updated via onBalanceUpdate on every streaming token — caused topPanel
// (ModelPickerRow) to re-render on every cost delta. Before this move: topPanel
// read viewModel.currentBalance → ContentView subscribed to ViewModel for balance
// → every balance update re-rendered topPanel + all its children.
// After: ModelPickerRow receives `streaming` reference and reads streaming.currentBalance
// directly — balance updates are isolated to ModelPickerRow only.
//
// CPU-23: currentToolCall setter routes through streaming.setToolCall() — throttled to 200ms.
// Direct writes to streaming.currentToolCall are replaced with setToolCall() so the
// thinkingView animation fires at most 5x/sec instead of 30+/sec during tool calls.

import SwiftUI
import ChappieCore
import SwiftData

@Observable
@MainActor
final class ChappieViewModel {

    // MARK: - Pagination constants (CPU-01)

    let pageSize = 30
    let pageSizeLoad = 30
    let maxDisplayed = 60

    // MARK: - CPU-13: Isolated streaming state

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

    // CPU-23: throttled via setToolCall()
    var currentToolCall: String? {
        get { streaming.currentToolCall }
        set { streaming.setToolCall(newValue) }
    }

    /// CPU-15: balance forwarded to/from StreamingState.
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
    var isAppReady: Bool = false
    var currentRequestTask: Task<Void, Never>? = nil
    var showNoProviderAlert: Bool = false
    var _syncTask: Task<Void, Never>? = nil
    var isFileSystemReady: Bool = true

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
    /// CatalogPickerSheet uses this instead of creating a new instance each time.
    let providersRemoteService = ProvidersRemoteService()

    // MARK: - SwiftData

    var modelContainer: ModelContainer?
    var memoryStore: MemoryStore?
    var threadStore: ThreadStore?
    var projectStore: ProjectStore?
    var providerStore: AIProviderStore?

    // MARK: - AppSettingsStore + caches

    var appSettingsStore: AppSettingsStore?
    var cachedBalances: [UUID: Double] = [:]
    var cachedLastActiveThreadId: UUID?
    var _activeThreadSession: ThreadSession?

    // MARK: - Init

    public init() {
        loadWorkspaceWithSecurityScope()
    }

    // MARK: - Pagination (CPU-01)

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

        if displayedMessages.count > maxDisplayed {
            let excess = displayedMessages.count - maxDisplayed
            displayedMessages = Array(displayedMessages.dropLast(excess))
        }
    }

    func appendToDisplayed(_ message: ChatMessage) {
        displayedMessages.append(message)
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

        connectAppSettingsStore(container: container)

        if let mm = memoryManager { Task { await mm.setMemoryStore(store) } }

        print("[ChappieViewModel] ModelContainer connected")

        if let ts = toolService {
            registerProjectToolHandlers(toolService: ts, projectStore: pStore, threadStore: tStore)
        }

        Task {
            await preloadLastActiveThreadId()
            await refreshBalanceCacheIfNeeded()
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
