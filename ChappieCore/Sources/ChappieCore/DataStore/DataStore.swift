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
// SCALABILITY CONTRACT:
// Adding new domain types = adding a Relation case + a Codable struct.
// No SwiftData migrations ever needed — the schema is frozen at one record type.
//
// CODABLE COMPATIBILITY RULES (enforced here and in all stored structs):
//   1. Never rename a stored property without adding CodingKeys.
//   2. Never remove a stored property — mark optional with a default instead.
//   3. Always give new properties a default value so old records decode cleanly.
//
// THREAD SAFETY:
// DataStore is an actor. ModelContext is created per-operation (not stored),
// which is the correct pattern for background SwiftData usage in Swift 6.

import Foundation
import SwiftData

// MARK: - StoredRecord

/// The only @Model in the application.
/// One row per Relation — payload is the full JSON-encoded domain collection.
@Model
public final class StoredRecord {

    // Unique relation key — matches DataStore.Relation.rawValue.
    // @Attribute(.unique) ensures exactly one row per relation.
    @Attribute(.unique) public var relation: String

    // JSON-encoded payload. Encoding/decoding is handled by DataStore — callers never touch this.
    public var payload: Data

    public init(relation: String, payload: Data) {
        self.relation = relation
        self.payload = payload
    }
}

// MARK: - DataStore

/// Actor-isolated facade over SwiftData.
/// All Stores (MemoryStore, ThreadStore, etc.) use this as their only persistence backend.
public actor DataStore {

    // MARK: - Relation

    /// Typesafe keys for StoredRecord rows.
    /// Each case maps to exactly one row in the database.
    public enum Relation: String {
        case threads        = "threads"
        case projects       = "projects"
        case memory         = "memory"
        case providers      = "providers"
        case appSettings    = "app_settings"
    }

    // MARK: - Dependencies

    private let modelContainer: ModelContainer

    // MARK: - Init

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Private helpers

    /// Creates a fresh ModelContext per operation — not stored, not shared.
    /// WHY: ModelContext is not Sendable and must not cross actor boundaries.
    private func makeContext() -> ModelContext {
        ModelContext(modelContainer)
    }

    /// Fetches the StoredRecord for a given relation, or nil if absent.
    private func findRecord(_ relation: Relation, in context: ModelContext) throws -> StoredRecord? {
        let key = relation.rawValue
        let descriptor = FetchDescriptor<StoredRecord>(
            predicate: #Predicate { $0.relation == key }
        )
        return try context.fetch(descriptor).first
    }

    // MARK: - Read

    /// Decodes the stored payload for a relation into type T.
    /// Returns nil if the record doesn't exist or decoding fails.
    /// Decoding failure is intentionally non-fatal — callers provide fallbacks.
    public func load<T: Codable>(_ relation: Relation) throws -> T? {
        let context = makeContext()
        guard let record = try findRecord(relation, in: context) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: record.payload)
        } catch {
            print("[DataStore] ⚠️ Decode failed for '\(relation.rawValue)': \(error)")
            return nil
        }
    }

    // MARK: - Write

    /// Encodes value and upserts the StoredRecord for the given relation.
    /// Creates a new record if absent; replaces payload if present.
    public func save<T: Codable>(_ value: T, for relation: Relation) throws {
        let context = makeContext()
        let data = try JSONEncoder().encode(value)

        if let existing = try findRecord(relation, in: context) {
            existing.payload = data
        } else {
            context.insert(StoredRecord(relation: relation.rawValue, payload: data))
        }

        try context.save()
    }

    // MARK: - Delete

    /// Removes the StoredRecord for the given relation entirely.
    /// Safe to call even if the record doesn't exist.
    public func delete(_ relation: Relation) throws {
        let context = makeContext()
        guard let record = try findRecord(relation, in: context) else { return }
        context.delete(record)
        try context.save()
        print("[DataStore] 🗑 Deleted relation '\(relation.rawValue)'")
    }

    // MARK: - Existence check

    /// Returns true if a record exists for the given relation.
    public func exists(_ relation: Relation) throws -> Bool {
        let context = makeContext()
        return try findRecord(relation, in: context) != nil
    }
}
