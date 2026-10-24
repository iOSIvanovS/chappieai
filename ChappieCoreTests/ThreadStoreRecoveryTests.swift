// ThreadStoreRecoveryTests.swift
// ChappieCoreTests
//
// Backlog 2b: threads whose list entry is lost are rebuilt from their message chunks.
// Each scenario seeds data with one ThreadStore and "restarts the app" with a fresh one,
// because a warm cache would hide the damaged record.

import Testing
import Foundation
@testable import ChappieCore

private let fallbackTitle = "Recovered chat"

private func makeStorage() throws -> SQLiteStorage { try SQLiteStorage(inMemory: true) }

/// A fresh store over the same data = an app restart.
private func restart(_ storage: SQLiteStorage) -> ThreadStore {
    ThreadStore(dataStore: storage, recoveredThreadTitle: fallbackTitle)
}

/// Same JSON shape the app's ChatMessage encodes to.
private struct Msg: Codable {
    var type = "message"
    var isUser: Bool
    var text: String
}

private func seedThread(_ storage: SQLiteStorage, title: String, messages: [Msg]) async throws -> UUID {
    let seeder = restart(storage)
    let id = try await seeder.createThread(title: title)
    try await seeder.replaceAllMessages(messages, toThreadId: id)
    return id
}

private func destroyList(_ storage: SQLiteStorage) async throws {
    try await storage.saveRawData(Data("garbage".utf8), for: .threads)
}

@Suite("ThreadStore recovery")
struct ThreadStoreRecoveryTests {

    @Test("Unreadable list: threads come back with the same ids and all their messages")
    func rebuildsFromChunks() async throws {
        let storage = try makeStorage()
        let a = try await seedThread(storage, title: "A", messages: [Msg(isUser: true, text: "Hello world"), Msg(isUser: false, text: "Hi")])
        let b = try await seedThread(storage, title: "B", messages: [Msg(isUser: false, text: "bot first"), Msg(isUser: true, text: "My question")])
        try await destroyList(storage)

        let store = restart(storage)
        let threads = try await store.loadThreads()

        #expect(Set(threads.map(\.id)) == [a, b])
        #expect(Set(threads.map(\.title)) == ["Hello world", "My question"])
        #expect(try await store.loadAllMessages(fromThreadId: a, as: Msg.self).count == 2)

        let issues = await store.takeIntegrityIssues()
        #expect(issues.count == 1)
        #expect(issues.first?.recoveredCount == 2)
        #expect(issues.first?.kind == .threadListUnreadable)
    }

    @Test("The repaired list is persisted: later loads are clean and report nothing")
    func repairHappensOnce() async throws {
        let storage = try makeStorage()
        _ = try await seedThread(storage, title: "A", messages: [Msg(isUser: true, text: "x")])
        try await destroyList(storage)

        let store = restart(storage)
        _ = try await store.loadThreads()
        _ = await store.takeIntegrityIssues()
        _ = try await store.exportAllPayloads()
        _ = try await store.exportAllPayloads()
        // Even a second app start finds a healthy list.
        let second = restart(storage)
        #expect(try await second.loadThreads().count == 1)

        #expect(await store.takeIntegrityIssues().isEmpty)
        #expect(await second.takeIntegrityIssues().isEmpty)
        #expect(try await storage.keys(withPrefix: "threads.corrupt.").count == 1)
    }

    @Test("Thread without user messages gets the fallback title")
    func usesFallbackTitle() async throws {
        let storage = try makeStorage()
        _ = try await seedThread(storage, title: "A", messages: [Msg(isUser: false, text: "only bot")])
        try await destroyList(storage)

        #expect(try await restart(storage).loadThreads().first?.title == fallbackTitle)
    }

    @Test("Long first message is cut to a short one-line title")
    func longTitleIsTruncated() async throws {
        let storage = try makeStorage()
        let long = String(repeating: "a", count: 200)
        _ = try await seedThread(storage, title: "A", messages: [Msg(isUser: true, text: long + "\nsecond line")])
        try await destroyList(storage)

        let title = try #require(try await restart(storage).loadThreads().first?.title)
        #expect(title.count == 41)
        #expect(title.hasSuffix("…"))
    }

    @Test("Readable threads keep settings; only the lost thread is rebuilt, keeping its surviving title")
    func partialDamageRebuildsOnlyMissing() async throws {
        let storage = try makeStorage()
        var settings = ThreadSettings()
        settings.maxMessagesInContext = 77
        let seeder = restart(storage)
        let keepId = try await seeder.createThread(title: "Keep", settings: settings)
        let lostId = try await seeder.createThread(title: "Lost")
        try await seeder.replaceAllMessages([Msg(isUser: true, text: "from chunks")], toThreadId: lostId)

        let encoded = try JSONEncoder().encode(try await seeder.exportAllPayloads())
        var array = try #require(try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        let lostIndex = try #require(array.firstIndex { $0["id"] as? String == lostId.uuidString })
        array[lostIndex] = ["id": lostId.uuidString, "title": "Lost"] // required fields missing -> undecodable
        try await storage.saveRawData(try JSONSerialization.data(withJSONObject: array), for: .threads)

        let store = restart(storage)
        let threads = try await store.loadThreads()

        #expect(threads.count == 2)
        #expect(threads.first(where: { $0.id == keepId })?.settings.maxMessagesInContext == 77)
        #expect(threads.first(where: { $0.id == lostId })?.title == "Lost")
        let issue = try #require(await store.takeIntegrityIssues().first)
        #expect(issue.kind == .threadListPartial(lostCount: 1))
        #expect(issue.recoveredCount == 1)
    }

    @Test("Same ids bring thread memory back")
    func threadMemorySurvives() async throws {
        let storage = try makeStorage()
        let id = try await seedThread(storage, title: "A", messages: [Msg(isUser: true, text: "x")])
        let memory = MemoryStore(dataStore: storage)
        try await memory.saveEntry(key: "note", type: "fact", jsonString: "remember", scope: id.uuidString)
        try await destroyList(storage)

        let rebuilt = try #require(try await restart(storage).loadThreads().first)

        #expect(rebuilt.id == id)
        #expect(try await memory.readAllEntries(scope: rebuilt.id.uuidString).count == 1)
    }

    @Test("A healthy list never resurrects chunks of a deleted thread")
    func healthyListIgnoresStrayChunks() async throws {
        let storage = try makeStorage()
        _ = try await restart(storage).createThread(title: "Alive")
        try await storage.saveRawData(Data("[]".utf8), for: .threadMessagesChunk(UUID(), 0))

        let store = restart(storage)
        #expect(try await store.loadThreads().count == 1)
        #expect(await store.takeIntegrityIssues().isEmpty)
    }

    @Test("Concurrent loads of a damaged list repair it once")
    func concurrentRepairIsSingle() async throws {
        let storage = try makeStorage()
        _ = try await seedThread(storage, title: "A", messages: [Msg(isUser: true, text: "x")])
        try await destroyList(storage)
        let store = restart(storage)

        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<6 { group.addTask { try await store.exportAllPayloads().count } }
            for try await count in group { #expect(count == 1) }
        }

        #expect(await store.takeIntegrityIssues().count == 1)
        #expect(try await storage.keys(withPrefix: "threads.corrupt.").count == 1)
    }

    @Test("Backup failure aborts the repair and leaves the damaged record untouched")
    func backupFailureWritesNothing() async throws {
        let inner = try makeStorage()
        let garbage = Data("garbage".utf8)
        try await inner.saveRawData(garbage, for: .threads)
        let store = ThreadStore(dataStore: BackupFailingStorage(inner: inner))

        await #expect(throws: (any Error).self) { _ = try await store.loadThreads() }
        #expect(try await inner.loadRawData(.threads) == garbage)
    }
}

/// Storage whose corrupt-record backup always fails; everything else is forwarded.
private actor BackupFailingStorage: ChappieStorage {
    struct Failure: Error {}
    let inner: SQLiteStorage
    init(inner: SQLiteStorage) { self.inner = inner }

    func load<T: Codable & Sendable>(_ relation: ChappieStorageRelation) async throws -> T? { try await inner.load(relation) }
    func loadRawData(_ relation: ChappieStorageRelation) async throws -> Data? { try await inner.loadRawData(relation) }
    func save<T: Codable & Sendable>(_ value: T, for relation: ChappieStorageRelation) async throws { try await inner.save(value, for: relation) }
    func saveRawData(_ data: Data, for relation: ChappieStorageRelation) async throws { try await inner.saveRawData(data, for: relation) }
    func delete(_ relation: ChappieStorageRelation) async throws { try await inner.delete(relation) }
    func deleteByPrefix(_ prefix: String) async throws { try await inner.deleteByPrefix(prefix) }
    func replaceIndexedRecords(prefix: String, fromIndex: Int, payloads: [Data]) async throws {
        try await inner.replaceIndexedRecords(prefix: prefix, fromIndex: fromIndex, payloads: payloads)
    }
    func preserveCorruptedRecord(key: String, data: Data) async throws -> String { throw Failure() }
    func exists(_ relation: ChappieStorageRelation) async throws -> Bool { try await inner.exists(relation) }
    func keys(withPrefix prefix: String) async throws -> [String] { try await inner.keys(withPrefix: prefix) }
}
