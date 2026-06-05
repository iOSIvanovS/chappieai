// MemoryStore.swift
// ChappieCore
//
// Actor managing the three-level memory system via ChappieDataStore.
// Scopes: "global", "<projectId>", "<threadId>".
//
// STORAGE LAYOUT:
// All scopes are stored as a single MemoryStorage record under ChappieDataStore.Relation.memory.
// MemoryStorage is a Codable struct: { scopes: [String: [MemoryEntry]] }.
// This means one ChappieDataStore round-trip loads all scopes — efficient for system prompt assembly.
//
// WHY ACTOR:
// Multiple concurrent tool calls may read/write memory simultaneously.
// Actor serializes access and prevents data races without explicit locking.
//
// CODABLE COMPATIBILITY (enforced — see DataStore.swift for full rules):
// MemoryEntry fields must never be renamed without CodingKeys.
// Removed fields must become optional with a default value.
// New fields must have a default value so old records decode cleanly.

import Foundation

// MARK: - MemoryStore

/// Actor managing memory entries via ChappieDataStore.
/// Single source of truth for all memory scopes.
public actor MemoryStore {

    private let dataStore: ChappieDataStore

    public init(dataStore: ChappieDataStore) {
        self.dataStore = dataStore
    }

    // MARK: - Private helpers

    /// Loads the full MemoryStorage from ChappieDataStore. Returns empty storage on miss or decode failure.
    private func loadStorage() async throws -> MemoryStorage {
        return (try await dataStore.load(.memory)) ?? MemoryStorage()
    }

    /// Saves the full MemoryStorage back to ChappieDataStore.
    private func saveStorage(_ storage: MemoryStorage) async throws {
        try await dataStore.save(storage, for: .memory)
    }

    // MARK: - Write

    /// Upserts a memory entry by key within the given scope.
    public func saveEntry(
        key: String,
        type: String,
        jsonString: String,
        scope: String
    ) async throws {
        var storage = try await loadStorage()
        var entries = storage.scopes[scope] ?? []

        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index].jsonString = jsonString
            entries[index].type = type
            entries[index].updatedAt = Date()
        } else {
            entries.append(MemoryEntry(key: key, type: type, jsonString: jsonString))
        }

        storage.scopes[scope] = entries
        try await saveStorage(storage)
        print("[MemoryStore] ✅ Saved '\(key)' in scope='\(scope)'")
    }

    // MARK: - Read

    public func readEntry(key: String, scope: String) async throws -> String? {
        let storage = try await loadStorage()
        return storage.scopes[scope]?.first(where: { $0.key == key })?.jsonString
    }

    /// Returns all entries for a scope. Used by buildSystemPrompt().
    public func readAllEntries(scope: String) async throws -> [MemoryEntry] {
        let storage = try await loadStorage()
        return storage.scopes[scope] ?? []
    }

    public func searchEntries(type: String, scope: String) async throws -> [String: String] {
        let storage = try await loadStorage()
        let entries = storage.scopes[scope] ?? []
        var results: [String: String] = [:]
        for entry in entries where entry.type == type {
            results[entry.key] = entry.jsonString
        }
        return results
    }

    // MARK: - Delete

    public func deleteEntry(key: String, scope: String) async throws {
        var storage = try await loadStorage()
        guard var entries = storage.scopes[scope] else {
            print("[MemoryStore] ℹ️ Entry '\(key)' not found in scope='\(scope)'")
            return
        }

        let countBefore = entries.count
        entries.removeAll { $0.key == key }

        guard entries.count < countBefore else {
            print("[MemoryStore] ℹ️ Entry '\(key)' not found in scope='\(scope)'")
            return
        }

        storage.scopes[scope] = entries
        try await saveStorage(storage)
        print("[MemoryStore] 🗑 Deleted '\(key)' from scope='\(scope)'")
    }

    /// Deletes the entire scope — used when a thread or project is deleted.
    public func deleteScope(_ scope: String) async throws {
        var storage = try await loadStorage()
        storage.scopes.removeValue(forKey: scope)
        try await saveStorage(storage)
        print("[MemoryStore] 🗑 Deleted scope='\(scope)'")
    }

    // MARK: - Bulk read for system prompt

    /// Loads entries for multiple scopes in a single ChappieDataStore fetch.
    /// Used by buildSystemPrompt() to avoid N separate round-trips.
    public func readEntriesForScopes(_ scopes: [String]) async throws -> [String: [MemoryEntry]] {
        let storage = try await loadStorage()
        let scopeSet = Set(scopes)
        var result: [String: [MemoryEntry]] = [:]
        for (scope, entries) in storage.scopes where scopeSet.contains(scope) {
            result[scope] = entries
        }
        return result
    }

    /// Bulk-imports entries into a scope (used by MigrationService).
    /// Replaces all existing entries in the scope.
    public func importEntries(_ entries: [MemoryEntry], intoScope scope: String) async throws {
        var storage = try await loadStorage()
        storage.scopes[scope] = entries
        try await saveStorage(storage)
        print("[MemoryStore] 📦 Imported \(entries.count) entries into scope='\(scope)'")
    }
}
