// DataStore.swift
// ChappieCore
//
// THE single point of contact with SwiftData in the entire application.
// No other file may import SwiftData or declare @Model — only this one.
//
// ARCHITECTURE:
// StoredRecord is the only @Model. Its schema never changes.
// All domain objects (threads, projects, memory, providers, settings) are
// encoded to Data via JSONEncoder and stored as payload inside a StoredRecord.
// Decoding failure is non-fatal — callers receive nil or [] and handle gracefully.
//
// RELATION DESIGN:
// Static cases (.threads, .providers, etc.) hold collections.
// Dynamic cases (.threadMessages, .projectBookmark) hold per-entity data
// and generate unique keys via UUID — e.g. "thread_messages.<uuid>".
// This avoids loading all messages when only the thread list is needed.
//
// MESSAGES STORAGE:
// Thread messages are stored as raw JSON Data under .threadMessages(<uuid>).
// saveRawData / loadRawData bypass JSONEncoder/Decoder — the data IS the payload.
// This is safe because messages come in as already-encoded JSON from ThreadStore.
//
// CODABLE COMPATIBILITY RULES (enforced here and in all stored structs):
//   1. Never rename a stored property without adding CodingKeys.
//   2. Never remove a stored property — mark optional with a default instead.
//   3. Always give new properties a default value so old records decode cleanly.
//
// THREAD SAFETY:
// ChappieDataStore is an actor. All public methods are async — callers use await.
// ModelContext is created per-operation (not stored), which is the correct pattern
// for background SwiftData usage in Swift 6.
//
// WHY ChappieDataStore (not DataStore):
// SwiftData framework exports its own `DataStore` protocol — naming conflict avoided
// by prefixing with Chappie. The actor name is unique across the entire codebase.

import Foundation
import SwiftData

// MARK: - StoredRecord

/// The only @Model in the application.
/// One row per Relation — payload is the full JSON-encoded domain collection.
@Model
public final class StoredRecord {

    @Attribute(.unique) public var relation: String
    public var payload: Data

    public init(relation: String, payload: Data) {
        self.relation = relation
        self.payload = payload
    }
}

// MARK: - ChappieDataStore

/// Actor-isolated facade over SwiftData.
/// All Stores (MemoryStore, ThreadStore, etc.) use this as their only persistence backend.
public actor ChappieDataStore {

    // MARK: - Relation

    /// Typesafe keys for StoredRecord rows. Sendable — safe to pass across actor boundaries.
    /// Static cases = one row per collection.
    /// Dynamic cases = one row per entity (keyed by UUID).
    public enum Relation: Sendable {
        case threads
        case projects
        case memory
        case providers
        case appSettings
        case threadMessages(UUID)
        case projectBookmark(UUID)

        public var key: String {
            switch self {
            case .threads:                  return "threads"
            case .projects:                 return "projects"
            case .memory:                   return "memory"
            case .providers:                return "providers"
            case .appSettings:              return "app_settings"
            case .threadMessages(let id):   return "thread_messages.\(id.uuidString)"
            case .projectBookmark(let id):  return "project_bookmark.\(id.uuidString)"
            }
        }
    }

    // MARK: - Dependencies

    private let modelContainer: ModelContainer

    // MARK: - Init

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Private helpers

    private func makeContext() -> ModelContext {
        ModelContext(modelContainer)
    }

    private func findRecord(_ relation: Relation, in context: ModelContext) throws -> StoredRecord? {
        let key = relation.key
        let descriptor = FetchDescriptor<StoredRecord>(
            predicate: #Predicate { $0.relation == key }
        )
        return try context.fetch(descriptor).first
    }

    // MARK: - Read (Codable)

    /// Decodes the stored payload for a relation into type T.
    /// Returns nil if the record doesn't exist or decoding fails.
    /// Decoding failure is intentionally non-fatal — callers provide fallbacks.
    public func load<T: Codable>(_ relation: Relation) async throws -> T? {
        let context = makeContext()
        guard let record = try findRecord(relation, in: context) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: record.payload)
        } catch {
            print("[ChappieDataStore] ⚠️ Decode failed for '\(relation.key)': \(error)")
            return nil
        }
    }

    // MARK: - Read (Raw Data)

    /// Returns the raw payload Data without any decoding.
    /// Used for thread messages — the data is already valid JSON from the encoder.
    public func loadRawData(_ relation: Relation) async throws -> Data? {
        let context = makeContext()
        return try findRecord(relation, in: context)?.payload
    }

    // MARK: - Write (Codable)

    /// Encodes value and upserts the StoredRecord for the given relation.
    public func save<T: Codable>(_ value: T, for relation: Relation) async throws {
        let context = makeContext()
        let data = try JSONEncoder().encode(value)

        if let existing = try findRecord(relation, in: context) {
            existing.payload = data
        } else {
            context.insert(StoredRecord(relation: relation.key, payload: data))
        }

        try context.save()
    }

    // MARK: - Write (Raw Data)

    /// Stores raw Data directly as the payload — no encoding step.
    /// Used for thread messages that are already JSON-encoded by the caller.
    public func saveRawData(_ data: Data, for relation: Relation) async throws {
        let context = makeContext()

        if let existing = try findRecord(relation, in: context) {
            existing.payload = data
        } else {
            context.insert(StoredRecord(relation: relation.key, payload: data))
        }

        try context.save()
    }

    // MARK: - Delete

    public func delete(_ relation: Relation) async throws {
        let context = makeContext()
        guard let record = try findRecord(relation, in: context) else { return }
        context.delete(record)
        try context.save()
        print("[ChappieDataStore] 🗑 Deleted relation '\(relation.key)'")
    }

    // MARK: - Existence check

    public func exists(_ relation: Relation) async throws -> Bool {
        let context = makeContext()
        return try findRecord(relation, in: context) != nil
    }
}
