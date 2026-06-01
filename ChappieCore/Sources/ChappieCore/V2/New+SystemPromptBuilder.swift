// New+SystemPromptBuilder.swift
// ChappieCore / V2
//
// Deterministic system prompt assembler for the V2 thread isolation architecture.
// Replaces the ad-hoc prompt assembly scattered across MemoryManager + AIOrchestrator.
//
// CONTRACT: same inputs → same output. No side effects, no external calls.
// Callers: New.ThreadSession (M-05), ChappieViewModel (M-06, behind FeatureFlags).
//
// Injection order (matches architecture-thread-isolation.md §3):
//   [1] Persona + 14 rules       — hardcoded, always present
//   [2] userName                 — if set in AppSettings
//   [3] Global memory            — if not empty
//   [4] Thread memory            — if not empty
//   [5] Per-project block        — settings + memory, one block per valid project
//   [6] (Tool manifest injected separately by AIOrchestrator, not here)
//
// Empty sections are omitted — no wasted tokens.

import Foundation

extension New {

    // MARK: - Input model

    /// All data needed to build one complete system prompt.
    /// Assembled by ThreadSession from SwiftData entities before calling build().
    public struct PromptContext: Sendable {
        public let userName: String?
        public let globalMemory: [MemoryEntry]
        public let threadMemory: [MemoryEntry]
        public let projects: [ProjectContext]

        public struct ProjectContext: Sendable {
            public let name: String
            public let settings: ProjectSettings
            public let memory: [MemoryEntry]

            public init(name: String, settings: ProjectSettings, memory: [MemoryEntry]) {
                self.name = name
                self.settings = settings
                self.memory = memory
            }
        }

        public init(
            userName: String? = nil,
            globalMemory: [MemoryEntry] = [],
            threadMemory: [MemoryEntry] = [],
            projects: [ProjectContext] = []
        ) {
            self.userName = userName
            self.globalMemory = globalMemory
            self.threadMemory = threadMemory
            self.projects = projects
        }

        public static let empty = PromptContext()
    }

    // MARK: - Tool permissions model

    /// Which tools are available for a given thread context.
    /// Used by AIOrchestrator to filter the tool manifest sent to the model.
    public struct ToolPermissions: Sendable {
        public let canReadFiles: Bool       // list_files, read_file
        public let canWriteFiles: Bool      // write_file, delete_file
        public let gitLevel: GitAccessLevel // controls which git_* tools are included
        public let canRunTests: Bool        // build_project, run_tests
        public let canWriteTests: Bool      // write test files
        public let canReadBuildLog: Bool    // read_build_log

        // Always available regardless of project settings.
        public let alwaysOn: Set<String> = [
            "web_fetch",
            "memorize", "recall", "search_memory", "delete_memory",
            "add_project_to_thread", "remove_project_from_thread", "list_thread_projects"
        ]

        public static let readOnly = ToolPermissions(
            canReadFiles: true,
            canWriteFiles: false,
            gitLevel: .none,
            canRunTests: false,
            canWriteTests: false,
            canReadBuildLog: false
        )

        public static let none = ToolPermissions(
            canReadFiles: false,
            canWriteFiles: false,
            gitLevel: .none,
            canRunTests: false,
            canWriteTests: false,
            canReadBuildLog: false
        )

        public init(
            canReadFiles: Bool,
            canWriteFiles: Bool,
            gitLevel: GitAccessLevel,
            canRunTests: Bool,
            canWriteTests: Bool,
            canReadBuildLog: Bool
        ) {
            self.canReadFiles = canReadFiles
            self.canWriteFiles = canWriteFiles
            self.gitLevel = gitLevel
            self.canRunTests = canRunTests
            self.canWriteTests = canWriteTests
            self.canReadBuildLog = canReadBuildLog
        }
    }

    // MARK: - SystemPromptBuilder

    /// Assembles the full system prompt from a PromptContext.
    /// Pure value transformer — no async, no SwiftData, no side effects.
    public struct SystemPromptBuilder {

        // Persona block is the same as in AIOrchestrator.baseSystemPrompt.
        // Stored here so V2 path owns its own copy — no dependency on AIOrchestrator.
        private let personaBlock: String

        public init(personaBlock: String) {
            self.personaBlock = personaBlock
        }

        // MARK: - Build

        /// Assembles the complete system prompt string.
        public func build(context: PromptContext) -> String {
            var sections: [String] = [personaBlock]

            // [2] User name
            if let name = context.userName, !name.isEmpty {
                sections.append("The user's name is \(name).")
            }

            // [3] Global memory
            if let block = memoryBlock(title: "Global Memory", entries: context.globalMemory) {
                sections.append(block)
            }

            // [4] Thread memory
            if let block = memoryBlock(title: "Thread Context", entries: context.threadMemory) {
                sections.append(block)
            }

            // [5] Per-project blocks
            for project in context.projects {
                var projectSections: [String] = []

                projectSections.append(project.settings.formatForSystemPrompt(projectName: project.name))

                if let memBlock = memoryBlock(
                    title: "Project Memory: \(project.name)",
                    entries: project.memory
                ) {
                    projectSections.append(memBlock)
                }

                sections.append(projectSections.joined(separator: "\n\n"))
            }

            // Wrap memory context in a separator block if anything beyond persona was added.
            if sections.count > 1 {
                let memoryHeader = "---\n## Memory Context"
                let tail = sections.dropFirst().joined(separator: "\n\n")
                return personaBlock + "\n\n" + memoryHeader + "\n\n" + tail
            }

            return personaBlock
        }

        // MARK: - Tool permissions

        /// Derives tool permissions from the projects in the context.
        /// Merges permissions across all attached projects (most permissive wins).
        public func toolPermissions(for context: PromptContext) -> ToolPermissions {
            guard !context.projects.isEmpty else {
                // No projects → read-only by default (safe fallback).
                return .readOnly
            }

            var canReadFiles = false
            var canWriteFiles = false
            var highestGit = GitAccessLevel.none
            var canRunTests = false
            var canWriteTests = false
            var canReadBuildLog = false

            for project in context.projects {
                let s = project.settings

                if s.agentRole == .advisor || s.agentRole == .executor {
                    canReadFiles = true
                }

                if s.agentRole == .executor {
                    canWriteFiles = true

                    // Merge git level — take the highest across projects.
                    if gitLevelRank(s.gitAccess) > gitLevelRank(highestGit) {
                        highestGit = s.gitAccess
                    }

                    if s.isProgrammingProject {
                        canRunTests = canRunTests || s.testsAccess.canRun
                        canWriteTests = canWriteTests || s.testsAccess.canWrite
                        canReadBuildLog = canReadBuildLog || s.testsAccess.canReadLog
                    }
                }
            }

            return ToolPermissions(
                canReadFiles: canReadFiles,
                canWriteFiles: canWriteFiles,
                gitLevel: highestGit,
                canRunTests: canRunTests,
                canWriteTests: canWriteTests,
                canReadBuildLog: canReadBuildLog
            )
        }

        // MARK: - Private helpers

        private func memoryBlock(title: String, entries: [MemoryEntry]) -> String? {
            guard !entries.isEmpty else { return nil }

            var lines = ["## \(title)"]
            for entry in entries.sorted(by: { $0.key < $1.key }) {
                let displayValue = formatEntryValue(entry.jsonString)
                lines.append("- [\(entry.type)] \(entry.key): \(displayValue)")
            }
            return lines.joined(separator: "\n")
        }

        /// Unwraps single-value JSON objects for readability.
        /// { "value": "foo" } → "foo". Anything else → raw string.
        private func formatEntryValue(_ jsonString: String) -> String {
            guard let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let first = json.values.first
            else {
                return jsonString
            }
            return "\(first)"
        }

        /// Numeric rank for git access levels — used to pick the highest across projects.
        private func gitLevelRank(_ level: GitAccessLevel) -> Int {
            switch level {
            case .none:       return 0
            case .statusOnly: return 1
            case .write:      return 2
            case .full:       return 3
            }
        }
    }
}
