// MemoryStore.swift
// ChappieCore
//
// Actor for CRUD operations on the three-level memory system via SwiftData.
// Scopes: "global", "<projectId>", "<threadId>".
//
// Thin persistence layer — knows nothing about memory content.
// Formatting for system prompt lives in MemoryManager.buildSystemPrompt().
//
// Why actor: ModelContext is not Sendable; actor ensures sequential access without data races.

import Foundation
import SwiftData

// MARK: - MemoryStore

/// Actor managing memory entries in SwiftData.
public actor MemoryStore {

    private let modelContainer: ModelContainer

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// ModelContext is not Sendable — create a new one per operation instead of storing it.
    private func makeContext() -> ModelContext {
        ModelContext(modelContainer)
    }

    // MARK: - Write

    /// Upserts a memory entry by key within the given scope.
    /// Creates the scope container if it doesn't exist yet.
    public func saveEntry(
        key: String,
        type: String,
        jsonString: String,
        scope: String
    ) throws {
        let context = makeContext()
        let entity = try findOrCreateEntity(scope: scope, in: context)

        var entries = entity.entries
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index].jsonString = jsonString
            entries[index].type = type
            entries[index].updatedAt = Date()
        } else {
            entries.append(MemoryEntry(key: key, type: type, jsonString: jsonString))
        }

        entity.setEntries(entries)
        try context.save()
        print("[MemoryStore] ✅ Saved '\(key)' in scope='\(scope)'")
    }

    // MARK: - Read

    public func readEntry(key: String, scope: String) throws -> String? {
        let context = makeContext()
        guard let entity = try findEntity(scope: scope, in: context) else { return nil }
        return entity.entries.first(where: { $0.key == key })?.jsonString
    }

    /// Returns all entries for a scope. Used by buildSystemPrompt().
    public func readAllEntries(scope: String) throws -> [MemoryEntry] {
        let context = makeContext()
        guard let entity = try findEntity(scope: scope, in: context) else { return [] }
        return entity.entries
    }

    public func searchEntries(type: String, scope: String) throws -> [String: String] {
        let context = makeContext()
        guard let entity = try findEntity(scope: scope, in: context) else { return [:] }
        var results: [String: String] = [:]
        for entry in entity.entries where entry.type == type {
            results[entry.key] = entry.jsonString
        }
        return results
    }

    // MARK: - Delete

    public func deleteEntry(key: String, scope: String) throws {
        let context = makeContext()
        guard let entity = try findEntity(scope: scope, in: context) else { return }

        var entries = entity.entries
        let countBefore = entries.count
        entries.removeAll { $0.key == key }

        guard entries.count < countBefore else {
            print("[MemoryStore] ℹ️ Entry '\(key)' not found in scope='\(scope)'")
            return
        }

        entity.setEntries(entries)
        try context.save()
        print("[MemoryStore] 🗑 Deleted '\(key)' from scope='\(scope)'")
    }

    /// Deletes the entire scope — used when a thread or project is deleted.
    public func deleteScope(_ scope: String) throws {
        let context = makeContext()
        guard let entity = try findEntity(scope: scope, in: context) else { return }
        context.delete(entity)
        try context.save()
        print("[MemoryStore] 🗑 Deleted scope='\(scope)'")
    }

    // MARK: - Bulk read for system prompt

    /// Loads entries for multiple scopes in a single SwiftData fetch.
    /// Used by buildSystemPrompt() to avoid N separate queries.
    ///
    /// Why not IN predicate: SwiftData #Predicate doesn't support array membership for strings.
    /// Fetching all entities and filtering in memory is faster for the typical 3–5 scopes.
    public func readEntriesForScopes(_ scopes: [String]) throws -> [String: [MemoryEntry]] {
        let context = makeContext()
        let allEntities = try context.fetch(FetchDescriptor<MemoryEntity>())
        let scopeSet = Set(scopes)
        var result: [String: [MemoryEntry]] = [:]
        for entity in allEntities where scopeSet.contains(entity.scope) {
            result[entity.scope] = entity.entries
        }
        return result
    }

    /// Bulk-imports entries into a scope (used by MigrationService).
    /// Replaces all existing entries in the scope.
    public func importEntries(_ entries: [MemoryEntry], intoScope scope: String) throws {
        let context = makeContext()
        let entity = try findOrCreateEntity(scope: scope, in: context)
        entity.setEntries(entries)
        try context.save()
        print("[MemoryStore] 📦 Imported \(entries.count) entries into scope='\(scope)'")
    }

    // MARK: - Private helpers

    private func findEntity(scope: String, in context: ModelContext) throws -> MemoryEntity? {
        let descriptor = FetchDescriptor<MemoryEntity>(
            predicate: #Predicate { $0.scope == scope }
        )
        return try context.fetch(descriptor).first
    }

    /// Finds or creates a MemoryEntity for the scope.
    /// New entity is inserted but NOT saved — caller must call save().
    private func findOrCreateEntity(scope: String, in context: ModelContext) throws -> MemoryEntity {
        if let existing = try findEntity(scope: scope, in: context) { return existing }
        let newEntity = MemoryEntity(scope: scope)
        context.insert(newEntity)
        return newEntity
    }
}
