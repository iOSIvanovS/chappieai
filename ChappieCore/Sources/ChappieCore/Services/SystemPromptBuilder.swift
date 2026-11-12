// SystemPromptBuilder.swift
// ChappieCore
//
// Deterministic system prompt assembler for the thread isolation architecture.
// Replaces the ad-hoc prompt assembly scattered across MemoryManager + AIOrchestrator.
//
// CONTRACT: same inputs → same output. No side effects, no external calls.
// Callers: ThreadSession, ChappieViewModel.
//
// Injection order: stable first, volatile last (providers cache the prefix).
//   [1] Persona + 14 rules       — hardcoded, always present
//   [2] userName                 — if set in AppSettings
//   [3] Project settings         — one block per project
//   [4] Global memory            — if not empty
//   [5] Thread memory            — if not empty
//   [6] Project memory           — one block per project, if not empty
//   (Tool manifest injected separately by AIOrchestrator, not here)
// A single "---" separates the persona from everything else; no wrapper header.
//
// Empty sections are omitted — no wasted tokens.
//
// TERMINAL:
// Thread-level terminal access is NOT injected here: the run_terminal / run_ssh tool
// descriptions carry that status (see ToolPolicy.status). The value stays in PromptContext
// only for tool gating.

import Foundation

// MARK: - Input model

/// All data needed to build one complete system prompt.
/// Assembled by ThreadSession from SwiftData entities before calling build().
public struct PromptContext: Sendable {
    public let userName: String?
    public let globalMemory: [MemoryEntry]
    public let threadMemory: [MemoryEntry]
    public let projects: [ProjectContext]
    /// Thread-level terminal access — independent of project roles.
    public let threadTerminalEnabled: Bool

    public struct ProjectContext: Sendable {
        public let name: String
        public let settings: ProjectSettings
        public let memory: [MemoryEntry]
        /// Absolute path on disk — resolved from security-scoped bookmark at runtime.
        /// Nil until syncFileSystemForActiveThread() completes successfully.
        public let absolutePath: String?

        public init(name: String, settings: ProjectSettings, memory: [MemoryEntry], absolutePath: String? = nil) {
            self.name = name
            self.settings = settings
            self.memory = memory
            self.absolutePath = absolutePath
        }
    }

    public init(
        userName: String? = nil,
        globalMemory: [MemoryEntry] = [],
        threadMemory: [MemoryEntry] = [],
        projects: [ProjectContext] = [],
        threadTerminalEnabled: Bool = false
    ) {
        self.userName = userName
        self.globalMemory = globalMemory
        self.threadMemory = threadMemory
        self.projects = projects
        self.threadTerminalEnabled = threadTerminalEnabled
    }

    public static let empty = PromptContext()
}

// MARK: - SystemPromptBuilder

/// Assembles the full system prompt from a PromptContext.
/// Pure value transformer — no async, no SwiftData, no side effects.
public struct SystemPromptBuilder {

    // Persona block is the same as in AIOrchestrator.baseSystemPrompt.
    // Stored here so this type owns its own copy — no dependency on AIOrchestrator.
    private let personaBlock: String

    public init(personaBlock: String) {
        self.personaBlock = personaBlock
    }

    // MARK: - Build

    /// Assembles the complete system prompt string.
    public func build(context: PromptContext) -> String {
        var sections: [String] = []

        // [2] User name
        if let name = context.userName, !name.isEmpty {
            sections.append("The user's name is \(name).")
        }

        // [3] Settings of every project: stable, rarely changes (keeps the cacheable prefix long).
        for project in context.projects {
            sections.append(project.settings.formatForSystemPrompt(
                projectName: project.name,
                absolutePath: project.absolutePath
            ))
        }

        // [4] Global memory
        if let block = memoryBlock(title: "Global Memory", entries: context.globalMemory) {
            sections.append(block)
        }

        // [5] Thread memory
        if let block = memoryBlock(title: "Thread Memory", entries: context.threadMemory) {
            sections.append(block)
        }

        // [6] Project memories: the most volatile part goes last.
        for project in context.projects {
            if let block = memoryBlock(title: "Project Memory: \(project.name)", entries: project.memory) {
                sections.append(block)
            }
        }

        guard !sections.isEmpty else { return personaBlock }
        return personaBlock + "\n\n---\n\n" + sections.joined(separator: "\n\n")
    }

    // MARK: - Private helpers

    private func memoryBlock(title: String, entries: [MemoryEntry]) -> String? {
        guard !entries.isEmpty else { return nil }

        var lines = ["## \(title)"]
        for entry in entries.sorted(by: { $0.key < $1.key }) {
            let displayValue = formatEntryValue(entry.jsonString)
            let dates = MessageTimestamp.entryDates(created: entry.createdAt, updated: entry.updatedAt)
            lines.append("- [\(entry.type)] \(entry.key) \(dates): \(displayValue)")
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
}
