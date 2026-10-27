// MemoryManager+SystemPrompt.swift
// ChappieCore
//
// System prompt assembly with injected memory context (IT-08, IT-09).
//
// Block order (IT-09): Project Settings → Global Memory → Project Memory → Thread Context.
// Project Settings is first so the agent knows its rights before reading memory.

import Foundation

extension MemoryManager {

    // MARK: - System prompt assembly (IT-08, IT-09)

    /// Builds the full system prompt with injected memory and project settings.
    public func buildSystemPrompt(
        basePrompt: String,
        memoryContext: MemoryContext
    ) async -> String {
        guard let store = memoryStore else {
            print("[MemoryManager] MemoryStore not connected, using base prompt only")
            return basePrompt
        }

        var scopes: [String] = ["global"]

        for info in memoryContext.projectInfos {
            scopes.append(info.id.uuidString)
        }

        if let threadId = memoryContext.threadId {
            scopes.append(threadId.uuidString)
        }

        let entriesByScope: [String: [MemoryEntry]]
        do {
            entriesByScope = try await store.readEntriesForScopes(scopes)
        } catch {
            print("[MemoryManager] Error loading memory from MemoryStore: \(error)")
            return basePrompt
        }

        var memoryBlocks: [String] = []

        // Project Settings first — agent must know its rights before seeing memory.
        for info in memoryContext.projectInfos {
            if let settings = info.settings {
                let settingsBlock = settings.formatForSystemPrompt(projectName: info.name)
                memoryBlocks.append(settingsBlock)
            }
        }

        // Global memory block.
        let globalEntries = entriesByScope["global"] ?? []
        if let block = formatEntriesForPrompt(globalEntries, title: "Global Memory") {
            memoryBlocks.append(block)
        }

        // One block per project.
        for info in memoryContext.projectInfos {
            let projectEntries = entriesByScope[info.id.uuidString] ?? []
            guard !projectEntries.isEmpty else { continue }
            if let block = formatEntriesForPrompt(projectEntries, title: "Project Memory: \(info.name)") {
                memoryBlocks.append(block)
            }
        }

        // Thread context.
        if let threadId = memoryContext.threadId {
            let threadEntries = entriesByScope[threadId.uuidString] ?? []
            if !threadEntries.isEmpty {
                if let block = formatEntriesForPrompt(threadEntries, title: "Thread Context") {
                    memoryBlocks.append(block)
                }
            }
        }

        guard !memoryBlocks.isEmpty else {
            return basePrompt
        }

        let memorySectionHeader = "---\n## Memory Context"
        let memorySection = ([memorySectionHeader] + memoryBlocks).joined(separator: "\n\n")

        return basePrompt + "\n\n" + memorySection
    }

    // MARK: - Legacy overload (IT-08 compat)

    public func buildSystemPrompt(
        basePrompt: String,
        threadId: UUID?,
        projectIds: [UUID]
    ) async -> String {
        let projectInfos = projectIds.map { id in
            MemoryContext.ProjectInfo(id: id, name: id.uuidString)
        }
        let context = MemoryContext(threadId: threadId, projectInfos: projectInfos)
        return await buildSystemPrompt(basePrompt: basePrompt, memoryContext: context)
    }

    // MARK: - Internal helpers

    /// Formats a list of entries into a titled memory block for the system prompt.
    func formatEntriesForPrompt(
        _ entries: [MemoryEntry],
        title: String,
        timeZone: TimeZone = .current
    ) -> String? {
        guard !entries.isEmpty else { return nil }

        var lines = ["## \(title)"]
        for entry in entries {
            let displayValue: String
            if let data = entry.jsonString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = json.values.first {
                displayValue = "\(value)"
            } else {
                displayValue = entry.jsonString
            }
            lines.append("- [\(entry.type)] \(entry.key) \(datesLabel(for: entry, timeZone: timeZone)): \(displayValue)")
        }

        return lines.joined(separator: "\n")
    }

    func datesLabel(for entry: MemoryEntry, timeZone: TimeZone) -> String {
        MessageTimestamp.entryDates(created: entry.createdAt, updated: entry.updatedAt, timeZone: timeZone)
    }
}
