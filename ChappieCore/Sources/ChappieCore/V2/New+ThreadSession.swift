// New+ThreadSession.swift
// ChappieCore / V2
//
// Runtime container for an active thread.
// Assembled on thread activation, discarded on thread switch.
//
// RESPONSIBILITIES:
//   - Loads all memory scopes for the active thread from SwiftData in one pass
//   - Resolves project settings from attached ProjectEntity records
//   - Builds PromptContext for SystemPromptBuilder
//   - Computes merged ToolPermissions for ToolAccessController
//   - Caches the built system prompt until explicitly invalidated
//
// CONTRACT:
//   - ThreadSession is NOT a SwiftData entity — it's a pure runtime object
//   - It reads from SwiftData but never writes to it
//   - Invalidate the cache whenever memory or project settings change
//   - Behind FeatureFlags.useThreadIsolationV2

import Foundation

extension New {

    // MARK: - ThreadSession

    /// Runtime container for one active thread.
    /// Assembled by ChappieViewModel when a thread becomes active.
    public actor ThreadSession {

        // MARK: - Stored properties

        private let thread: ThreadMetadata
        private let projects: [ProjectEntity]
        private let memoryStore: MemoryStore
        private let promptBuilder: SystemPromptBuilder
        private let userName: String?

        // Cached prompt — rebuilt only when invalidated.
        private var cachedSystemPrompt: String?
        private var cachedPermissions: ToolPermissions?

        // MARK: - Init

        public init(
            thread: ThreadMetadata,
            projects: [ProjectEntity],
            memoryStore: MemoryStore,
            promptBuilder: SystemPromptBuilder,
            userName: String? = nil
        ) {
            self.thread = thread
            self.projects = projects
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

        /// Returns merged ToolPermissions for this thread, building on first call.
        public func toolPermissions() async throws -> ToolPermissions {
            if let cached = cachedPermissions { return cached }

            let context = try await buildPromptContext()
            let permissions = promptBuilder.toolPermissions(for: context)
            cachedPermissions = permissions
            return permissions
        }

        /// Clears cached prompt and permissions — call after any memory or settings change.
        public func invalidateCache() {
            cachedSystemPrompt = nil
            cachedPermissions = nil
        }

        // MARK: - Private: context assembly

        /// Loads all memory scopes in one SwiftData fetch, then assembles PromptContext.
        private func buildPromptContext() async throws -> PromptContext {
            // Collect all scopes needed: global + thread + one per project.
            var scopes = ["global", thread.id.uuidString]
            for project in projects {
                scopes.append(project.id.uuidString)
            }

            // Single bulk fetch — avoids N round-trips to SwiftData.
            let entriesByScope = try await memoryStore.readEntriesForScopes(scopes)

            let globalMemory = entriesByScope["global"] ?? []
            let threadMemory = entriesByScope[thread.id.uuidString] ?? []

            // Build one ProjectContext per attached project.
            let projectContexts: [PromptContext.ProjectContext] = projects.map { entity in
                let projectMemory = entriesByScope[entity.id.uuidString] ?? []
                return PromptContext.ProjectContext(
                    name: entity.displayName,
                    settings: entity.settings,
                    memory: projectMemory
                )
            }

            return PromptContext(
                userName: userName,
                globalMemory: globalMemory,
                threadMemory: threadMemory,
                projects: projectContexts
            )
        }
    }
}
