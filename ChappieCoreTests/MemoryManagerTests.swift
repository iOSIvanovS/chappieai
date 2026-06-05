// MemoryManagerTests.swift
// ChappieCoreTests
//
// Tests for MemoryStore — the DataStore-backed memory layer.
//
// STRATEGY: each test creates a fresh in-memory ChappieDataStore + MemoryStore.
// No file I/O, no global state, no UUID cleanup needed.
// MemoryManager file-based API was removed in T-05; tests now target MemoryStore directly.

import Testing
import Foundation
import SwiftData
@testable import ChappieCore

// MARK: - Helpers

/// Creates an isolated in-memory ChappieDataStore for tests.
private func makeTestDataStore() throws -> ChappieDataStore {
    let schema = Schema([StoredRecord.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: config)
    return ChappieDataStore(modelContainer: container)
}

@Suite("MemoryManager Tests")
struct MemoryManagerTests {

    // MARK: - Save & Read

    @Test("Save and load a single entry")
    func saveAndLoad() async throws {
        let store = MemoryStore(dataStore: try makeTestDataStore())

        try await store.saveEntry(key: "k1", type: "fact", jsonString: "{\"v\":1}", scope: "global")
        let result = try await store.readEntry(key: "k1", scope: "global")

        #expect(result == "{\"v\":1}")
    }

    @Test("Read missing key returns nil")
    func readMissingKey() async throws {
        let store = MemoryStore(dataStore: try makeTestDataStore())
        let result = try await store.readEntry(key: "nonexistent", scope: "global")
        #expect(result == nil)
    }

    @Test("Overwrite existing entry updates value")
    func overwrite() async throws {
        let store = MemoryStore(dataStore: try makeTestDataStore())

        try await store.saveEntry(key: "k", type: "fact", jsonString: "\"old\"", scope: "global")
        try await store.saveEntry(key: "k", type: "fact", jsonString: "\"new\"", scope: "global")

        let result = try await store.readEntry(key: "k", scope: "global")
        #expect(result == "\"new\"")
    }

    // MARK: - Delete

    @Test("Delete removes entry, read returns nil")
    func deleteEntry() async throws {
        let store = MemoryStore(dataStore: try makeTestDataStore())

        try await store.saveEntry(key: "k", type: "fact", jsonString: "\"data\"", scope: "global")
        try await store.deleteEntry(key: "k", scope: "global")

        let result = try await store.readEntry(key: "k", scope: "global")
        #expect(result == nil)
    }

    @Test("Delete non-existent key does not throw")
    func deleteMissingKey() async throws {
        let store = MemoryStore(dataStore: try makeTestDataStore())
        // Must not throw
        try await store.deleteEntry(key: "ghost", scope: "global")
    }

    // MARK: - Search

    @Test("Search by type returns matching entries only")
    func searchByType() async throws {
        let store = MemoryStore(dataStore: try makeTestDataStore())

        try await store.saveEntry(key: "r1", type: "rule", jsonString: "\"rule1\"", scope: "global")
        try await store.saveEntry(key: "f1", type: "fact", jsonString: "\"fact1\"", scope: "global")
        try await store.saveEntry(key: "r2", type: "rule", jsonString: "\"rule2\"", scope: "global")

        let rules = try await store.searchEntries(type: "rule", scope: "global")

        #expect(rules.count == 2)
        #expect(rules["r1"] == "\"rule1\"")
        #expect(rules["r2"] == "\"rule2\"")
        #expect(rules["f1"] == nil)
    }

    @Test("Search missing type returns empty dict")
    func searchMissingType() async throws {
        let store = MemoryStore(dataStore: try makeTestDataStore())
        let result = try await store.searchEntries(type: "nonexistent", scope: "global")
        #expect(result.isEmpty)
    }

    // MARK: - Scope isolation

    @Test("Scopes are isolated — entry in scope A not visible in scope B")
    func scopeIsolation() async throws {
        let store = MemoryStore(dataStore: try makeTestDataStore())

        try await store.saveEntry(key: "k", type: "fact", jsonString: "\"A\"", scope: "scopeA")
        let fromB = try await store.readEntry(key: "k", scope: "scopeB")

        #expect(fromB == nil)
    }

    @Test("Delete scope removes all entries in that scope")
    func deleteScope() async throws {
        let store = MemoryStore(dataStore: try makeTestDataStore())

        try await store.saveEntry(key: "k1", type: "fact", jsonString: "\"v1\"", scope: "s1")
        try await store.saveEntry(key: "k2", type: "fact", jsonString: "\"v2\"", scope: "s1")
        try await store.saveEntry(key: "k3", type: "fact", jsonString: "\"v3\"", scope: "s2")

        try await store.deleteScope("s1")

        let r1 = try await store.readEntry(key: "k1", scope: "s1")
        let r2 = try await store.readEntry(key: "k2", scope: "s1")
        let r3 = try await store.readEntry(key: "k3", scope: "s2")

        #expect(r1 == nil)
        #expect(r2 == nil)
        #expect(r3 == "\"v3\"") // s2 untouched
    }

    // MARK: - Bulk read

    @Test("readEntriesForScopes returns entries for requested scopes only")
    func bulkRead() async throws {
        let store = MemoryStore(dataStore: try makeTestDataStore())

        try await store.saveEntry(key: "g1", type: "fact", jsonString: "\"gv\"", scope: "global")
        try await store.saveEntry(key: "t1", type: "fact", jsonString: "\"tv\"", scope: "thread1")
        try await store.saveEntry(key: "p1", type: "fact", jsonString: "\"pv\"", scope: "project1")

        let result = try await store.readEntriesForScopes(["global", "thread1"])

        #expect(result["global"]?.count == 1)
        #expect(result["thread1"]?.count == 1)
        #expect(result["project1"] == nil) // not requested
    }

    // MARK: - Multiple entries

    @Test("Multiple entries stored independently")
    func multipleEntries() async throws {
        let store = MemoryStore(dataStore: try makeTestDataStore())

        for i in 1...5 {
            try await store.saveEntry(key: "key\(i)", type: "fact", jsonString: "\"\(i)\"", scope: "global")
        }

        for i in 1...5 {
            let v = try await store.readEntry(key: "key\(i)", scope: "global")
            #expect(v == "\"\(i)\"")
        }
    }

    // MARK: - Import

    @Test("importEntries replaces all entries in scope")
    func importEntries() async throws {
        let store = MemoryStore(dataStore: try makeTestDataStore())

        try await store.saveEntry(key: "old", type: "fact", jsonString: "\"old\"", scope: "s")

        let newEntries = [
            MemoryEntry(key: "new1", type: "fact", jsonString: "\"n1\""),
            MemoryEntry(key: "new2", type: "fact", jsonString: "\"n2\"")
        ]
        try await store.importEntries(newEntries, intoScope: "s")

        let old = try await store.readEntry(key: "old", scope: "s")
        let n1 = try await store.readEntry(key: "new1", scope: "s")

        #expect(old == nil)
        #expect(n1 == "\"n1\"")
    }
}
