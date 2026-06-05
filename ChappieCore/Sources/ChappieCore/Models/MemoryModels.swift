// MemoryModels.swift
// ChappieCore
//
// Three-level memory system (IT-08):
//   "global"      — cross-project facts, user preferences
//   "<projectId>" — project-specific decisions, pipelines
//   "<threadId>"  — current task context, session notes
//
// STORAGE:
// All scopes are stored as a single MemoryStorage record in DataStore (Relation.memory).
// MemoryEntity (@Model) is kept only for DataStoreMigration (DB-02) and will be removed in DB-05.
//
// CODABLE COMPATIBILITY CONTRACT (enforced — see DataStore.swift for full rules):
//   1. Never rename a stored property without adding CodingKeys.
//   2. Never remove a stored property — mark optional with a default instead.
//   3. Always give new properties a default value so old records decode cleanly.

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

// MARK: - MemoryStorage

/// Root payload stored under DataStore.Relation.memory.
/// Holds all scopes in one Codable struct — one DataStore round-trip loads everything.
public struct MemoryStorage: Codable, Sendable {
    /// scope string → array of MemoryEntry
    public var scopes: [String: [MemoryEntry]]

    public init(scopes: [String: [MemoryEntry]] = [:]) {
        self.scopes = scopes
    }

    // CodingKeys guard against future renames.
    private enum CodingKeys: String, CodingKey {
        case scopes
    }
}

// MARK: - MemoryEntry

/// Single memory record — key/type/value triple, scoped via MemoryStorage.
///
/// CODABLE COMPATIBILITY: CodingKeys defined — safe to rename Swift properties
/// without breaking existing stored records, as long as raw values stay stable.
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

    // CodingKeys — stable raw values protect against Swift property renames.
    private enum CodingKeys: String, CodingKey {
        case id
        case key
        case type
        case jsonString = "json_string"
        case metadata
        case createdAt  = "created_at"
        case updatedAt  = "updated_at"
    }
}

// MARK: - MemoryEntity (legacy — kept for DataStoreMigration only, removed in DB-05)

/// SwiftData container for one memory scope.
/// DO NOT USE in new code — use MemoryStore + DataStore instead.
/// Kept alive so DataStoreMigration can read legacy records before DB-05 cleanup.
@Model
public final class MemoryEntity {

    public var id: UUID
    public var scope: String
    public var entriesJSON: Data
    public var updatedAt: Date

    public init(id: UUID = UUID(), scope: String, entries: [MemoryEntry] = []) {
        self.id = id
        self.scope = scope
        self.updatedAt = Date()
        self.entriesJSON = (try? JSONEncoder().encode(entries)) ?? Data()
    }
}

// MARK: - MemoryEntity helpers (migration use only)

extension MemoryEntity {

    /// Decodes entries from JSON. Returns empty array on failure.
    public var entries: [MemoryEntry] {
        guard !entriesJSON.isEmpty,
              let decoded = try? JSONDecoder().decode([MemoryEntry].self, from: entriesJSON)
        else { return [] }
        return decoded
    }

    /// Encodes and persists new entries.
    public func setEntries(_ newEntries: [MemoryEntry]) {
        if let data = try? JSONEncoder().encode(newEntries) {
            entriesJSON = data
            updatedAt = Date()
        }
    }
}
