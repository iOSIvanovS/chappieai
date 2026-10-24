// ThreadStoreWindowSaveTests.swift
// ChappieCoreTests
//
// Regression tests for backlog_01: saving a lazily loaded message window must never
// erase older chunks that are still only on disk.

import Testing
import Foundation
@testable import ChappieCore

private func makeStore() throws -> (ThreadStore, SQLiteStorage) {
    let storage = try SQLiteStorage(inMemory: true)
    return (ThreadStore(dataStore: storage), storage)
}

private struct TestMessage: Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    init(text: String) { self.id = UUID(); self.text = text }
}

/// Throws while encoding — simulates a failure BEFORE anything is written.
private struct PoisonMessage: Codable {
    var poison: Bool
    func encode(to encoder: Encoder) throws {
        if poison { throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "poison")) }
        var c = encoder.singleValueContainer()
        try c.encode("ok")
    }
    init(poison: Bool) { self.poison = poison }
    init(from decoder: Decoder) throws { self.poison = false }
}

private func makeMessages(_ count: Int, prefix: String = "msg") -> [TestMessage] {
    (0..<count).map { TestMessage(text: "\(prefix)_\($0)") }
}

@Suite("ThreadStore window save")
struct ThreadStoreWindowSaveTests {

    @Test("1200 on disk -> open last chunk -> append 1 -> 1201 on disk")
    func appendKeepsOlderHistory() async throws {
        let (store, _) = try makeStore()
        let id = try await store.createThread(title: "T")
        let original = makeMessages(1200)
        try await store.replaceAllMessages(original, toThreadId: id)

        // Simulate what the UI does: open (last chunk only), append, save the window.
        let (window, _) = try await store.loadMessages(fromThreadId: id, as: TestMessage.self)
        let startChunk = try #require(try await store.lastChunkIndex(forThreadId: id))
        let extra = TestMessage(text: "new")
        try await store.saveLoadedMessages(window + [extra], toThreadId: id, fromChunk: startChunk)

        let all = try await store.loadAllMessages(fromThreadId: id, as: TestMessage.self)
        #expect(all.count == 1201)
        #expect(Array(all.prefix(1200)) == original)
        #expect(all.last == extra)
    }

    @Test("Window that started mid-thread (older chunk scrolled in) saves from that chunk")
    func midThreadWindow() async throws {
        let (store, _) = try makeStore()
        let id = try await store.createThread(title: "T")
        let original = makeMessages(1200) // chunks 0,1,2 (500,500,200)
        try await store.replaceAllMessages(original, toThreadId: id)

        // User scrolled up once: window = chunks 1 and 2.
        let window = Array(original[500...])
        let extra = TestMessage(text: "new")
        try await store.saveLoadedMessages(window + [extra], toThreadId: id, fromChunk: 1)

        let all = try await store.loadAllMessages(fromThreadId: id, as: TestMessage.self)
        #expect(all.count == 1201)
        #expect(Array(all.prefix(500)) == Array(original[..<500]))
        #expect(all.last == extra)
    }

    @Test("Chunk boundary: window of exactly 500 + 1 new message splits into two chunks")
    func boundaryGrowth() async throws {
        let (store, _) = try makeStore()
        let id = try await store.createThread(title: "T")
        let first = makeMessages(500)
        try await store.saveLoadedMessages(first, toThreadId: id, fromChunk: 0)
        #expect(try await store.lastChunkIndex(forThreadId: id) == 0)

        let extra = TestMessage(text: "501st")
        try await store.saveLoadedMessages(first + [extra], toThreadId: id, fromChunk: 0)

        #expect(try await store.lastChunkIndex(forThreadId: id) == 1)
        let (last, hasMore) = try await store.loadMessages(fromThreadId: id, as: TestMessage.self)
        #expect(last == [extra])
        #expect(hasMore)
    }

    @Test("Shrinking window removes stale trailing chunks")
    func shrinkingRemovesTail() async throws {
        let (store, _) = try makeStore()
        let id = try await store.createThread(title: "T")
        try await store.replaceAllMessages(makeMessages(1200), toThreadId: id)

        // Window from chunk 1 is replaced by 10 messages: chunk 2 must disappear.
        try await store.saveLoadedMessages(makeMessages(10, prefix: "x"), toThreadId: id, fromChunk: 1)

        #expect(try await store.lastChunkIndex(forThreadId: id) == 1)
        let all = try await store.loadAllMessages(fromThreadId: id, as: TestMessage.self)
        #expect(all.count == 510)
    }

    @Test("Encoding failure leaves existing data untouched")
    func failureKeepsOldData() async throws {
        let (store, _) = try makeStore()
        let id = try await store.createThread(title: "T")
        let original = makeMessages(700)
        try await store.replaceAllMessages(original, toThreadId: id)

        // Second chunk contains a message that cannot be encoded.
        var poisoned = (0..<600).map { _ in PoisonMessage(poison: false) }
        poisoned[550].poison = true
        await #expect(throws: (any Error).self) {
            try await store.saveLoadedMessages(poisoned, toThreadId: id, fromChunk: 0)
        }

        let all = try await store.loadAllMessages(fromThreadId: id, as: TestMessage.self)
        #expect(all == original)
    }

    @Test("replaceAllMessages with empty array wipes the thread (clear memory)")
    func clearMemoryStillWipes() async throws {
        let (store, _) = try makeStore()
        let id = try await store.createThread(title: "T")
        try await store.replaceAllMessages(makeMessages(1200), toThreadId: id)

        try await store.replaceAllMessages([TestMessage](), toThreadId: id)

        #expect(try await store.lastChunkIndex(forThreadId: id) == nil)
        #expect(try await store.loadAllMessages(fromThreadId: id, as: TestMessage.self).isEmpty)
    }

    @Test("Saving thread A's window never touches thread B")
    func otherThreadUntouched() async throws {
        let (store, _) = try makeStore()
        let a = try await store.createThread(title: "A")
        let b = try await store.createThread(title: "B")
        let bMessages = makeMessages(700, prefix: "b")
        try await store.replaceAllMessages(bMessages, toThreadId: b)

        try await store.saveLoadedMessages(makeMessages(3), toThreadId: a, fromChunk: 0)

        #expect(try await store.loadAllMessages(fromThreadId: b, as: TestMessage.self) == bMessages)
    }

    @Test("saveLoadedMessages bumps thread updatedAt")
    func touchesUpdatedAt() async throws {
        let (store, _) = try makeStore()
        let id = try await store.createThread(title: "T")
        let before = try #require(try await store.loadThreads().first { $0.id == id }).updatedAt

        try await Task.sleep(nanoseconds: 20_000_000)
        try await store.saveLoadedMessages(makeMessages(1), toThreadId: id, fromChunk: 0)

        let after = try #require(try await store.loadThreads().first { $0.id == id }).updatedAt
        #expect(after > before)
    }

    @Test("replaceIndexedRecords compares suffix numerically (2 vs 10) and keeps lower indices")
    func numericSuffixSemantics() async throws {
        let storage = try SQLiteStorage(inMemory: true)
        let id = UUID()
        let prefix = ChappieStorageRelation.chunkPrefix(for: id)
        let seed = (0..<12).map { Data("old\($0)".utf8) }
        try await storage.replaceIndexedRecords(prefix: prefix, fromIndex: 0, payloads: seed)

        // Replace from index 2: indices 2...11 (including "10", "11") must go.
        try await storage.replaceIndexedRecords(prefix: prefix, fromIndex: 2, payloads: [Data("new".utf8)])

        let keys = try await storage.keys(withPrefix: prefix)
        #expect(keys.count == 3)
        let kept0 = try await storage.loadRawData(.threadMessagesChunk(id, 0))
        let kept1 = try await storage.loadRawData(.threadMessagesChunk(id, 1))
        let new2 = try await storage.loadRawData(.threadMessagesChunk(id, 2))
        #expect(kept0 == Data("old0".utf8))
        #expect(kept1 == Data("old1".utf8))
        #expect(new2 == Data("new".utf8))
    }
}
