// ChappieStorage.swift
// ChappieCore
//
// Protocol that abstracts the persistence backend.
// All Stores (ThreadStore, MemoryStore, etc.) depend on this — never on a concrete class.
//
// WHY A PROTOCOL:
// SwiftData crashed in production. We're migrating to SQLite via GRDB.
// The protocol lets us swap implementations without touching any Store.
// DI at the app entry point decides which backend is active.
//
// IMPLEMENTORS:
// - ChappieDataStore  — SwiftData backend (legacy, kept during migration)
// - SQLiteStorage     — GRDB backend (new, production target)

import Foundation

// MARK: - ChappieStorage

/// Persistence contract for all Stores in ChappieCore.
/// Actor-isolated — all methods are async and safe to call from any context.
public protocol ChappieStorage: Actor {

    // MARK: Read

    /// Decodes the stored payload for a relation into type T.
    /// Returns nil if the record doesn't exist or decoding fails.
    func load<T: Codable & Sendable>(_ relation: ChappieStorageRelation) async throws -> T?

    /// Returns raw payload Data without decoding.
    /// Used for thread messages that are already valid JSON.
    func loadRawData(_ relation: ChappieStorageRelation) async throws -> Data?

    // MARK: Write

    /// Encodes value and upserts the record for the given relation.
    func save<T: Codable & Sendable>(_ value: T, for relation: ChappieStorageRelation) async throws

    /// Stores raw Data directly — no encoding step.
    func saveRawData(_ data: Data, for relation: ChappieStorageRelation) async throws

    // MARK: Delete

    /// Deletes the record for the given relation. No-op if not found.
    func delete(_ relation: ChappieStorageRelation) async throws

    // MARK: Existence

    /// Returns true if a record exists for the given relation.
    func exists(_ relation: ChappieStorageRelation) async throws -> Bool
}

// MARK: - ChappieStorageRelation

/// Typesafe keys for storage rows.
/// Extracted from ChappieDataStore.Relation into a standalone type
/// so it can be used in the protocol without importing SwiftData.
public enum ChappieStorageRelation: Sendable, Hashable {
    case threads
    case projects
    case memory
    case providers
    case appSettings
    case threadMessages(UUID)

    public var key: String {
        switch self {
        case .threads:                  return "threads"
        case .projects:                 return "projects"
        case .memory:                   return "memory"
        case .providers:                return "providers"
        case .appSettings:              return "app_settings"
        case .threadMessages(let id):   return "thread_messages.\(id.uuidString)"
        }
    }
}
