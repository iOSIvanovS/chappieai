// ChappieStorage.swift
// ChappieCore
//
// Protocol that abstracts the persistence backend.
// All Stores (ThreadStore, MemoryStore, etc.) depend on this — never on a concrete class.
//
// WHY A PROTOCOL:
// Decouples business logic from storage implementation.
// DI at the app entry point decides which backend is active.
// Currently the sole implementor is SQLiteStorage (GRDB).

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
    func loadRawData(_ relation: ChappieStorageRelation) async throws -> Data?

    // MARK: Write

    /// Encodes value and upserts the record for the given relation.
    func save<T: Codable & Sendable>(_ value: T, for relation: ChappieStorageRelation) async throws

    /// Stores raw Data directly — no encoding step.
    func saveRawData(_ data: Data, for relation: ChappieStorageRelation) async throws

    // MARK: Delete

    /// Deletes the record for the given relation. No-op if not found.
    func delete(_ relation: ChappieStorageRelation) async throws

    /// Deletes all records whose key starts with the given prefix.
    /// Used to atomically delete all chunks of a thread.
    func deleteByPrefix(_ prefix: String) async throws

    /// Atomically replaces the tail of an indexed series of records.
    /// Keys look like "<prefix><integer>". In ONE transaction: deletes every row under `prefix`
    /// whose integer suffix is >= `fromIndex`, then writes `payloads` as fromIndex, fromIndex+1, ...
    /// Rows with a lower index are untouched. On failure nothing changes (rollback).
    func replaceIndexedRecords(prefix: String, fromIndex: Int, payloads: [Data]) async throws

    /// Copies an unreadable blob to "<key>.corrupt.<time>" and returns the backup key.
    /// Idempotent: if a backup with byte-identical content already exists, its key is returned
    /// and nothing new is written. Never touches the original record.
    func preserveCorruptedRecord(key: String, data: Data) async throws -> String

    // MARK: Existence

    /// Returns true if a record exists for the given relation.
    func exists(_ relation: ChappieStorageRelation) async throws -> Bool

    // MARK: Enumeration

    /// Returns all relation keys that start with the given prefix, sorted ascending.
    func keys(withPrefix prefix: String) async throws -> [String]
}

// MARK: - ChappieStorageRelation

/// Typesafe keys for storage rows.
public enum ChappieStorageRelation: Sendable, Hashable {
    case threads
    case projects
    case memory
    case providers
    case appSettings
    /// Chunked messages: "thread_messages_chunk.<UUID>.<index>" e.g. index = 0, 1, 2...
    case threadMessagesChunk(UUID, Int)

    public var key: String {
        switch self {
        case .threads:                              return "threads"
        case .projects:                             return "projects"
        case .memory:                               return "memory"
        case .providers:                            return "providers"
        case .appSettings:                          return "app_settings"
        case .threadMessagesChunk(let id, let i):   return "\(Self.chunkKeyRoot)\(id.uuidString).\(i)"
        }
    }

    /// Prefix used to enumerate or delete all chunks for a thread.
    public static func chunkPrefix(for threadId: UUID) -> String {
        return "\(chunkKeyRoot)\(threadId.uuidString)."
    }

    /// Common start of every message-chunk key, for scanning chunks of all threads at once.
    public static let chunkKeyRoot = "thread_messages_chunk."
}
