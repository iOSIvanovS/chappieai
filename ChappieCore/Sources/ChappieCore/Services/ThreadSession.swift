// ThreadSession.swift
// ChappieCore
//
// Runtime container for an active thread.
// Assembled on thread activation, discarded on thread switch.
//
// RESPONSIBILITIES:
//   - Loads all memory scopes for the active thread from SwiftData in one pass
//   - Resolves project settings from attached ProjectMetadata (Sendable DTOs)
//   - Builds PromptContext for SystemPromptBuilder
//   - Caches the built system prompt until explicitly invalidated
//
// CONTRACT:
//   - ThreadSession is NOT a SwiftData entity — it's a pure runtime object
//   - It reads from MemoryStore but never writes to it
//   - ProjectEntity (@Model) is NOT stored here — only Sendable ProjectMetadata
//   - Invalidate the cache whenever memory or project settings change

import Foundation

// MARK: - ThreadSession

/// Runtime container for one active thread.
/// Assembled by ChappieViewModel when a thread becomes active.
public actor ThreadSession {

    // MARK: - Stored properties

    private let thread: ThreadMetadata
    private let projectMetas: [ProjectMetadata]   // Sendable DTOs — no @Model here
    private let memoryStore: MemoryStore
    private let promptBuilder: SystemPromptBuilder
    private let userName: String?

    // Cached prompt — rebuilt only when invalidated.
    private var cachedSystemPrompt: String?

    // MARK: - Init

    public init(
        thread: ThreadMetadata,
        projectMetas: [ProjectMetadata],
        memoryStore: MemoryStore,
        promptBuilder: SystemPromptBuilder,
        userName: String? = nil
    ) {
        self.thread = thread
        self.projectMetas = projectMetas
        self.memoryStore = memoryStore
        self.promptBuilder = promptBuilder
        self.userName = userName
    }

    // MARK: - Public API

    /// Returns the cached system prompt, building it on first call.
    public func systemPrompt() async throws -> String {
        if let cached = cachedSystemPrompt { return cached }

        let context = try await buildPromptContext()
        let prompt = promptBuilder.build(context: context)
        cachedSystemPrompt = prompt
        return prompt
    }

    /// Clears the cached prompt — call after any memory or settings change.
    public func invalidateCache() {
        cachedSystemPrompt = nil
    }

    // MARK: - Private: context assembly

    /// Loads all memory scopes in one MemoryStore fetch, then assembles PromptContext.
    private func buildPromptContext() async throws -> PromptContext {
        // Collect all scopes: global + thread + one per project.
        var scopes = ["global", thread.id.uuidString]
        for meta in projectMetas {
            scopes.append(meta.id.uuidString)
        }

        // Single bulk fetch — avoids N round-trips to SwiftData.
        let entriesByScope = try await memoryStore.readEntriesForScopes(scopes)

        let globalMemory = entriesByScope["global"] ?? []
        let threadMemory = entriesByScope[thread.id.uuidString] ?? []

        // Build one ProjectContext per attached project using Sendable metadata.
        // absolutePath is runtime-only — resolved by syncFileSystemForActiveThread().
        let projectContexts: [PromptContext.ProjectContext] = projectMetas.map { meta in
            let projectMemory = entriesByScope[meta.id.uuidString] ?? []
            return PromptContext.ProjectContext(
                name: meta.displayName,
                settings: meta.settings,
                memory: projectMemory,
                absolutePath: meta.absolutePath
            )
        }

        return PromptContext(
            userName: userName,
            globalMemory: globalMemory,
            threadMemory: threadMemory,
            projects: projectContexts,
            threadTerminalAccess: thread.settings.terminalAccess
        )
    }
}
