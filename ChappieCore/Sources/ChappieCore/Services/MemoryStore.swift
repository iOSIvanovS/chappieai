// MemoryStore.swift
// ChappieCore
//
// Actor managing the three-level memory system via ChappieStorage protocol.
// Scopes: "global", "<projectId>", "<threadId>".
//
// STORAGE LAYOUT:
// All scopes are stored as a single MemoryStorage record under .memory relation.
// MemoryStorage is a Codable struct: { scopes: [String: [MemoryEntry]] }.
// One storage round-trip loads all scopes — efficient for system prompt assembly.

import Foundation

// MARK: - MemoryStore

public actor MemoryStore {

    private let dataStore: any ChappieStorage

    public init(dataStore: any ChappieStorage) {
        self.dataStore = dataStore
    }

    // MARK: - Private helpers

    private func loadStorage() async throws -> MemoryStorage {
        return (try await dataStore.load(.memory)) ?? MemoryStorage()
    }

    private func saveStorage(_ storage: MemoryStorage) async throws {
        try await dataStore.save(storage, for: .memory)
    }

    // MARK: - Write

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

    public func deleteScope(_ scope: String) async throws {
        var storage = try await loadStorage()
        storage.scopes.removeValue(forKey: scope)
        try await saveStorage(storage)
        print("[MemoryStore] 🗑 Deleted scope='\(scope)'")
    }

    // MARK: - Bulk read for system prompt

    /// Loads entries for multiple scopes in a single storage fetch.
    public func readEntriesForScopes(_ scopes: [String]) async throws -> [String: [MemoryEntry]] {
        let storage = try await loadStorage()
        let scopeSet = Set(scopes)
        var result: [String: [MemoryEntry]] = [:]
        for (scope, entries) in storage.scopes where scopeSet.contains(scope) {
            result[scope] = entries
        }
        return result
    }

    /// Bulk-imports entries into a scope. Replaces all existing entries in the scope.
    public func importEntries(_ entries: [MemoryEntry], intoScope scope: String) async throws {
        var storage = try await loadStorage()
        storage.scopes[scope] = entries
        try await saveStorage(storage)
        print("[MemoryStore] 📦 Imported \(entries.count) entries into scope='\(scope)'")
    }
}
