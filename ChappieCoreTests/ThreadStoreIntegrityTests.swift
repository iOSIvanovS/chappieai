// ThreadStoreIntegrityTests.swift
// ChappieCoreTests
//
// Regression tests for backlog_02a: an unreadable thread list must never be silently replaced
// by an empty one. The damaged bytes are backed up, readable threads are salvaged one by one,
// and the problem is reported to the UI.

import Testing
import Foundation
@testable import ChappieCore

private func makeStore() throws -> (ThreadStore, SQLiteStorage) {
    let storage = try SQLiteStorage(inMemory: true)
    return (ThreadStore(dataStore: storage), storage)
}

private func backups(_ storage: SQLiteStorage, of key: String) async throws -> [String] {
    try await storage.keys(withPrefix: "\(key).corrupt.")
}

@Suite("ThreadStore integrity")
struct ThreadStoreIntegrityTests {

    @Test("Missing thread list is simply empty — no issue, no backup")
    func missingIsNotCorruption() async throws {
        let (store, storage) = try makeStore()
        let threads = try await store.loadThreads()
        #expect(threads.isEmpty)
        #expect(await store.takeIntegrityIssues().isEmpty)
        #expect(try await backups(storage, of: "threads").isEmpty)
    }

    @Test("Garbage blob: empty list, backup holds the exact bytes, one issue reported")
    func unreadableBlobIsBackedUpAndReported() async throws {
        let (store, storage) = try makeStore()
        let garbage = Data("this is not json".utf8)
        try await storage.saveRawData(garbage, for: .threads)

        #expect(try await store.loadThreads().isEmpty)

        let issues = await store.takeIntegrityIssues()
        #expect(issues.count == 1)
        #expect(issues.first?.kind == .threadListUnreadable)

        let keys = try await backups(storage, of: "threads")
        #expect(keys.count == 1)
        #expect(issues.first?.backupKey == keys.first)
        let saved = try await storage.loadRawData(.threads)
        #expect(saved == garbage) // loading never overwrites the original
        let again = try await storage.preserveCorruptedRecord(key: "threads", data: garbage)
        #expect(again == keys.first) // the backup holds exactly the damaged bytes
    }

    @Test("Repeated loads of the same damage report once and keep one backup")
    func reportedOncePerBlob() async throws {
        let (store, storage) = try makeStore()
        try await storage.saveRawData(Data("garbage".utf8), for: .threads)

        // exportAllPayloads reads the stored list from disk on every call (no cache).
        for _ in 0..<5 { _ = try await store.exportAllPayloads() }

        #expect(await store.takeIntegrityIssues().count == 1)
        #expect(try await backups(storage, of: "threads").count == 1)
    }

    @Test("Creating a thread after damage keeps the backup of the old bytes")
    func overwriteAfterDamageKeepsBackup() async throws {
        let (store, storage) = try makeStore()
        let garbage = Data("{broken".utf8)
        try await storage.saveRawData(garbage, for: .threads)

        _ = try await store.createThread(title: "Fresh")

        let keys = try await backups(storage, of: "threads")
        #expect(keys.count == 1)
        // Asking to preserve the same bytes again returns the existing key only if the stored
        // backup holds exactly these bytes.
        let again = try await storage.preserveCorruptedRecord(key: "threads", data: garbage)
        #expect(again == keys.first)
        #expect(try await store.loadThreads().count == 1)
    }

    @Test("One broken element: the other threads survive with their settings")
    func partialSalvage() async throws {
        let (store, storage) = try makeStore()
        var settings = ThreadSettings()
        settings.maxMessagesInContext = 77
        let good1 = ThreadPayload(title: "Keep me", settings: settings)
        let good2 = ThreadPayload(title: "Me too")
        let encoded = try JSONEncoder().encode([good1, good2])
        var array = try #require(try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        array.insert(["id": "not-a-uuid", "title": 42], at: 1)
        try await storage.saveRawData(try JSONSerialization.data(withJSONObject: array), for: .threads)

        let threads = try await store.loadThreads()

        #expect(Set(threads.map(\.title)) == ["Keep me", "Me too"])
        #expect(threads.first(where: { $0.title == "Keep me" })?.settings.maxMessagesInContext == 77)
        let issues = await store.takeIntegrityIssues()
        #expect(issues.count == 1)
        #expect(issues.first?.kind == .threadListPartial(lostCount: 1))
        #expect(try await backups(storage, of: "threads").count == 1)
    }

    @Test("A healthy list produces no issues and no backups")
    func healthyListIsQuiet() async throws {
        let (store, storage) = try makeStore()
        _ = try await store.createThread(title: "A")
        _ = try await store.createThread(title: "B")

        #expect(try await store.loadThreads().count == 2)
        #expect(await store.takeIntegrityIssues().isEmpty)
        #expect(try await backups(storage, of: "threads").isEmpty)
    }

    @Test("takeIntegrityIssues hands issues over once")
    func issuesAreTakenOnce() async throws {
        let (store, storage) = try makeStore()
        try await storage.saveRawData(Data("x".utf8), for: .threads)
        _ = try await store.loadThreads()

        #expect(await store.takeIntegrityIssues().count == 1)
        #expect(await store.takeIntegrityIssues().isEmpty)
    }
}

@Suite("SQLiteStorage corrupt-record backup")
struct SQLiteCorruptBackupTests {

    @Test("Same bytes twice -> same backup key; different bytes -> a second backup")
    func idempotentAndDistinct() async throws {
        let storage = try SQLiteStorage(inMemory: true)
        let a = Data("aaa".utf8), b = Data("bbb".utf8)

        let k1 = try await storage.preserveCorruptedRecord(key: "threads", data: a)
        let k2 = try await storage.preserveCorruptedRecord(key: "threads", data: a)
        let k3 = try await storage.preserveCorruptedRecord(key: "threads", data: b)

        #expect(k1 == k2)
        #expect(k3 != k1)
        #expect(try await storage.keys(withPrefix: "threads.corrupt.").count == 2)
    }

    @Test("Undecodable memory blob is backed up before defaults take over")
    func memoryBlobBackedUp() async throws {
        let storage = try SQLiteStorage(inMemory: true)
        let store = MemoryStore(dataStore: storage)
        let garbage = Data("nope".utf8)
        try await storage.saveRawData(garbage, for: .memory)

        let entries = try await store.readAllEntries(scope: "global")

        #expect(entries.isEmpty)
        #expect(try await storage.keys(withPrefix: "memory.corrupt.").count == 1)
    }
}
