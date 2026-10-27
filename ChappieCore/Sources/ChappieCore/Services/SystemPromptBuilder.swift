// SystemPromptBuilder.swift
// ChappieCore
//
// Deterministic system prompt assembler for the thread isolation architecture.
// Replaces the ad-hoc prompt assembly scattered across MemoryManager + AIOrchestrator.
//
// CONTRACT: same inputs → same output. No side effects, no external calls.
// Callers: ThreadSession, ChappieViewModel.
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
//
// TERMINAL:
// Thread-level terminal access is injected as a standalone line in the Memory Context block.
// It is independent of any project settings — the AI reads it from the thread context.

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
    public let threadTerminalAccess: TerminalAccessLevel

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
        threadTerminalAccess: TerminalAccessLevel = .none
    ) {
        self.userName = userName
        self.globalMemory = globalMemory
        self.threadMemory = threadMemory
        self.projects = projects
        self.threadTerminalAccess = threadTerminalAccess
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

        // [4b] Thread-level terminal access — injected as a standalone line.
        // WHY HERE: terminal is thread-scoped, not project-scoped.
        // The AI must know the terminal mode before deciding whether to call run_terminal.
        let terminalLine = threadTerminalLine(context.threadTerminalAccess)
        sections.append(terminalLine)

        // [5] Per-project blocks
        for project in context.projects {
            var projectSections: [String] = []

            // Pass absolutePath so AI sees it in the project settings block.
            projectSections.append(project.settings.formatForSystemPrompt(
                projectName: project.name,
                absolutePath: project.absolutePath
            ))

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

    // MARK: - Private helpers

    private func threadTerminalLine(_ access: TerminalAccessLevel) -> String {
        switch access {
        case .none:
            return "## Thread Settings: Terminal\n- Terminal: BLOCKED (enable in thread settings)"
        case .confirm:
            return "## Thread Settings: Terminal\n- Terminal: enabled with confirmation. BEFORE running any command you MUST ask the user for explicit approval in chat. Do NOT call run_terminal until user says 'yes', 'go ahead', or equivalent."
        case .auto:
            return "## Thread Settings: Terminal\n- Terminal: enabled, auto-execute (no confirmation needed). Use responsibly."
        }
    }

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
