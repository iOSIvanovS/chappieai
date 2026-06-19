// MemoryModels.swift
// ChappieCore
//
// Three-level memory system (IT-08):
//   "global"      — cross-project facts, user preferences
//   "<projectId>" — project-specific decisions, pipelines
//   "<threadId>"  — current task context, session notes
//
// STORAGE:
// All scopes are stored as a single MemoryStorage record in ChappieDataStore (Relation.memory).
// ChappieDataStore is the ONLY place that knows about SwiftData — see DataStore.swift.
//
// CODABLE COMPATIBILITY CONTRACT (never violate — stored JSON must always decode cleanly):
//   1. Never rename a stored property without adding/updating CodingKeys.
//   2. Never remove a stored property — mark optional with a default instead.
//   3. Always give new properties a default value so old records decode cleanly.

import Foundation

// MARK: - ActiveMemoryContext

/// Active memory context passed to ToolExecutionService.
/// Carries thread UUID, attached project UUIDs, resolved project paths, and thread-level terminal access.
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

    /// Map of project display name → absolute path on disk.
    /// Used by run_terminal to prefix commands with `cd /path && ` for deterministic execution.
    /// Populated after bookmark resolution in syncFileSystemForActiveThread().
    /// Empty until first successful resolution — terminal will fall back to no-cd behavior.
    public let projectPathMap: [String: String]

    /// Thread-level terminal access. Independent of project roles.
    /// Starter plan forces this to .none across all threads.
    public let threadTerminalAccess: TerminalAccessLevel

    public init(
        threadId: UUID? = nil,
        projects: [ProjectInfo] = [],
        projectPathMap: [String: String] = [:],
        threadTerminalAccess: TerminalAccessLevel = .none
    ) {
        self.threadId = threadId
        self.projects = projects
        self.projectPathMap = projectPathMap
        self.threadTerminalAccess = threadTerminalAccess
    }

    /// Fallback before ModelContainer is initialized.
    public static let empty = ActiveMemoryContext(threadId: nil, projects: [], projectPathMap: [:], threadTerminalAccess: .none)

    /// Used in PROJECT GUARD to block file tools when no project is attached.
    public var hasProjects: Bool { !projects.isEmpty }

    public var projectNames: [String] { projects.map { $0.name } }
    public var projectIds: [UUID] { projects.map { $0.id } }
}

// MARK: - MemoryStorage

/// Root payload stored under ChappieDataStore.Relation.memory.
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
