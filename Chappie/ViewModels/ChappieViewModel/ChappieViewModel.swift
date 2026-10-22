// ChappieViewModel.swift
// Chappie
//
// Core @Observable class: state declarations, init, history management, drafts, balance.
// Business logic is split into extensions:
//   +Boot, +Workspace, +Pagination, +Threads, +ThreadProvider, +ThreadGreeting,
//   +ThreadSettings, +ThreadSession, +Providers, +Projects, +Send,
//   +Memory, +AppSettings, +License, +Terminal

import SwiftUI
import ChappieCore

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

    // Live terminal window state — isolated so shell output ticks don't invalidate ContentView.
    let terminal = TerminalLiveState()

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

    /// True when older storage chunks exist for the active thread (not yet loaded into memory).
    /// Distinct from hasMoreMessages — that controls UI pagination within already-loaded messages.
    var hasMoreChunks: Bool = false
    /// The chunk index of the oldest chunk currently loaded. Used by loadOlderMessages().
    var oldestLoadedChunkIndex: Int? = nil

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

    // MARK: - Backup (export/import for machine migration)

    var backupService: BackupService?

    // MARK: - Project maps for MCP routing

    /// Map of project display name → DevEnvironment rawValue.
    /// WHY loop instead of uniqueKeysWithValues: duplicate displayNames crash with preconditionFailure.
    var activeProjectEnvMap: [String: String] {
        var map: [String: String] = [:]
        for project in activeProjects where project.settings.isProgrammingProject && project.settings.devEnvironment != .unknown {
            map[project.displayName] = project.settings.devEnvironment.rawValue
        }
        return map
    }

    /// Map of project display name → absolute path on disk.
    /// WHY loop instead of uniqueKeysWithValues: duplicate displayNames crash with preconditionFailure.
    var activeProjectPathMap: [String: String] {
        var map: [String: String] = [:]
        for project in activeProjects {
            guard let path = project.absolutePath else { continue }
            map[project.displayName] = path
        }
        return map
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

    // MARK: - Draft Management

    func getDraft(for threadId: UUID) -> String { threadDrafts[threadId] ?? "" }
    func setDraft(_ text: String, for threadId: UUID) { threadDrafts[threadId] = text }
    func clearDraft(for threadId: UUID) { threadDrafts.removeValue(forKey: threadId) }

    // MARK: - Balance

    func refreshBalanceForActiveProvider() {
        guard let provider = activeProvider else { return }
        self.currentBalance = loadBalance(for: provider.id)
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
}
