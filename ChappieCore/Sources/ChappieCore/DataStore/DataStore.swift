// DataStore.swift
// ChappieCore
//
// Legacy SwiftData backend. Kept alive during migration to SQLite.
// Once MigrationService confirms all data is in SQLite — this file is deleted.
//
// ARCHITECTURE:
// ChappieDataStore now conforms to ChappieStorage protocol.
// All Stores depend on ChappieStorage, not this class directly.
// ChappieDataStore.Relation is deprecated — use ChappieStorageRelation instead.
//
// THREAD SAFETY:
// Actor-isolated. All public methods are async.
// ModelContext is created per-operation — correct pattern for background SwiftData usage.

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

/// Legacy SwiftData persistence backend. Conforms to ChappieStorage.
/// Do not add new features here — all new work goes into SQLiteStorage.
public actor ChappieDataStore: ChappieStorage {

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

    private func findRecord(_ relation: ChappieStorageRelation, in context: ModelContext) throws -> StoredRecord? {
        let key = relation.key
        let descriptor = FetchDescriptor<StoredRecord>(
            predicate: #Predicate { $0.relation == key }
        )
        return try context.fetch(descriptor).first
    }

    // MARK: - ChappieStorage

    public func load<T: Codable & Sendable>(_ relation: ChappieStorageRelation) async throws -> T? {
        let context = makeContext()
        guard let record = try findRecord(relation, in: context) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: record.payload)
        } catch {
            print("[ChappieDataStore] ⚠️ Decode failed for '\(relation.key)': \(error)")
            return nil
        }
    }

    public func loadRawData(_ relation: ChappieStorageRelation) async throws -> Data? {
        let context = makeContext()
        return try findRecord(relation, in: context)?.payload
    }

    public func save<T: Codable & Sendable>(_ value: T, for relation: ChappieStorageRelation) async throws {
        let context = makeContext()
        let data = try JSONEncoder().encode(value)

        if let existing = try findRecord(relation, in: context) {
            existing.payload = data
        } else {
            context.insert(StoredRecord(relation: relation.key, payload: data))
        }

        try context.save()
    }

    public func saveRawData(_ data: Data, for relation: ChappieStorageRelation) async throws {
        let context = makeContext()

        if let existing = try findRecord(relation, in: context) {
            existing.payload = data
        } else {
            context.insert(StoredRecord(relation: relation.key, payload: data))
        }

        try context.save()
    }

    public func delete(_ relation: ChappieStorageRelation) async throws {
        let context = makeContext()
        guard let record = try findRecord(relation, in: context) else { return }
        context.delete(record)
        try context.save()
        print("[ChappieDataStore] 🗑 Deleted relation '\(relation.key)'")
    }

    public func exists(_ relation: ChappieStorageRelation) async throws -> Bool {
        let context = makeContext()
        return try findRecord(relation, in: context) != nil
    }
}
