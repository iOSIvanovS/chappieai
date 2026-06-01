// MemoryModels.swift
// ChappieCore
//
// Three-level memory system (IT-08):
//   "global"      — cross-project facts, user preferences
//   "<projectId>" — project-specific decisions, pipelines
//   "<threadId>"  — current task context, session notes
// All levels share one SwiftData table, differentiated by scope string.

import Foundation
import SwiftData

// MARK: - ActiveMemoryContext

/// Active memory context passed to ToolExecutionService.
/// Carries thread UUID and attached project UUIDs for scope mapping.
public struct ActiveMemoryContext: Sendable {

    /// Project identity: UUID for scope mapping, name for tool targetName lookup.
    public struct ProjectInfo: Sendable {
        public let id: UUID
        public let name: String

        public init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// Active thread UUID. nil = no active thread, thread memory unavailable.
    public let threadId: UUID?

    /// Projects attached to the active thread. Empty = project memory unavailable.
    public let projects: [ProjectInfo]

    public init(threadId: UUID? = nil, projects: [ProjectInfo] = []) {
        self.threadId = threadId
        self.projects = projects
    }

    /// Fallback before ModelContainer is initialized.
    public static let empty = ActiveMemoryContext(threadId: nil, projects: [])

    /// Used in PROJECT GUARD to block file tools when no project is attached.
    public var hasProjects: Bool { !projects.isEmpty }

    public var projectNames: [String] { projects.map { $0.name } }
    public var projectIds: [UUID] { projects.map { $0.id } }
}

// MARK: - MemoryEntity

/// SwiftData container for one memory scope.
/// Stores all entries as a single JSON blob — we always read the full scope at once.
@Model
public final class MemoryEntity {

    public var id: UUID
    public var scope: String   // "global", project UUID, or thread UUID
    public var entriesJSON: Data  // encoded [MemoryEntry]; Dictionary fields require Data, not direct storage
    public var updatedAt: Date

    public init(id: UUID = UUID(), scope: String, entries: [MemoryEntry] = []) {
        self.id = id
        self.scope = scope
        self.updatedAt = Date()
        self.entriesJSON = (try? JSONEncoder().encode(entries)) ?? Data()
    }
}

// MARK: - MemoryEntry

/// Single memory record — key/type/value triple, scoped to a MemoryEntity.
public struct MemoryEntry: Codable, Sendable, Identifiable, Equatable {

    public let id: UUID
    public var key: String
    public var type: String

    /// Content stored as a JSON string for schema flexibility across different record types.
    public var jsonString: String

    public var metadata: [String: String]?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        key: String,
        type: String,
        jsonString: String,
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.key = key
        self.type = type
        self.jsonString = jsonString
        self.metadata = metadata
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - MemoryEntity helpers

extension MemoryEntity {

    /// Decodes entries from JSON. Returns empty array on failure.
    public var entries: [MemoryEntry] {
        guard !entriesJSON.isEmpty,
              let decoded = try? JSONDecoder().decode([MemoryEntry].self, from: entriesJSON)
        else { return [] }
        return decoded
    }

    /// Encodes and persists new entries. SwiftData tracks the change automatically.
    public func setEntries(_ newEntries: [MemoryEntry]) {
        if let data = try? JSONEncoder().encode(newEntries) {
            entriesJSON = data
            updatedAt = Date()
        } else {
            print("[MemoryModels] ⚠️ Failed to serialize entries for scope='\(scope)'")
        }
    }

    /// Formats memory entries as a prompt block.
    ///
    /// Output:
    /// ```
    /// ## <title>
    /// - [type] key: value
    /// ```
    /// Returns nil if there are no entries.
    public func formatForPrompt(title: String) -> String? {
        let currentEntries = entries
        guard !currentEntries.isEmpty else { return nil }

        var lines = ["## \(title)"]
        for entry in currentEntries {
            // Try to extract a readable scalar from the JSON string
            let displayValue: String
            if let data = entry.jsonString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = json.values.first {
                displayValue = "\(value)"
            } else {
                displayValue = entry.jsonString
            }
            lines.append("- [\(entry.type)] \(entry.key): \(displayValue)")
        }

        return lines.joined(separator: "\n")
    }
}
