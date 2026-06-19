// ThreadStoreTests.swift
// ChappieCoreTests
//
// Tests for ThreadStore chunk system — the core of lazy message loading.
//
// COVERAGE:
// - Basic chunk roundtrip (write → read all)
// - Lazy load: loadMessages returns only the last chunk + correct hasMore flag
// - Pagination: loadMoreMessages walks chunks backwards
// - Boundary: exactly CHUNK_SIZE (500) messages fills one chunk, 501 splits into two
// - deleteThread removes all chunks atomically
// - deleteOldMessages trims from the front and re-chunks correctly
//
// ISOLATION:
// Each test creates a fresh in-memory SQLiteStorage — no shared state, no file I/O.

import Testing
import Foundation
@testable import ChappieCore

// MARK: - Helpers

private func makeStore() throws -> ThreadStore {
    let storage = try SQLiteStorage(inMemory: true)
    return ThreadStore(dataStore: storage)
}

/// Minimal Codable message for testing — mirrors ChatMessage structure.
private struct TestMessage: Codable, Equatable, Sendable {
    let id: UUID
    let text: String

    init(text: String) {
        self.id = UUID()
        self.text = text
    }
}

/// Generates N unique test messages.
private func makeMessages(_ count: Int) -> [TestMessage] {
    (0..<count).map { TestMessage(text: "msg_\($0)") }
}

// MARK: - Suite

@Suite("ThreadStore Chunk System")
struct ThreadStoreTests {

    // MARK: - Roundtrip

    @Test("Write and read all messages — small batch")
    func roundtripSmall() async throws {
        let store = try makeStore()
        let threadId = try await store.createThread(title: "Test")
        let messages = makeMessages(10)

        try await store.saveMessages(messages, toThreadId: threadId)
        let loaded = try await store.loadAllMessages(fromThreadId: threadId, as: TestMessage.self)

        #expect(loaded == messages)
    }

    @Test("Write and read all messages — 1200 messages (3 chunks)")
    func roundtripLarge() async throws {
        let store = try makeStore()
        let threadId = try await store.createThread(title: "Large")
        let messages = makeMessages(1200)

        try await store.saveMessages(messages, toThreadId: threadId)
        let loaded = try await store.loadAllMessages(fromThreadId: threadId, as: TestMessage.self)

        #expect(loaded.count == 1200)
        #expect(loaded == messages)
    }

    // MARK: - Boundary

    @Test("Exactly 500 messages — single chunk, hasMore = false")
    func boundary500() async throws {
        let store = try makeStore()
        let threadId = try await store.createThread(title: "Boundary500")
        let messages = makeMessages(500)

        try await store.saveMessages(messages, toThreadId: threadId)
        let (loaded, hasMore) = try await store.loadMessages(fromThreadId: threadId, as: TestMessage.self)

        #expect(loaded.count == 500)
        #expect(hasMore == false)
    }

    @Test("501 messages — two chunks, hasMore = true")
    func boundary501() async throws {
        let store = try makeStore()
        let threadId = try await store.createThread(title: "Boundary501")
        let messages = makeMessages(501)

        try await store.saveMessages(messages, toThreadId: threadId)
        let (loaded, hasMore) = try await store.loadMessages(fromThreadId: threadId, as: TestMessage.self)

        // Last chunk has 1 message (the 501st)
        #expect(loaded.count == 1)
        #expect(hasMore == true)
    }

    // MARK: - Lazy Load

    @Test("loadMessages returns only the last chunk")
    func lazyLoadReturnsLastChunk() async throws {
        let store = try makeStore()
        let threadId = try await store.createThread(title: "Lazy")
        // 3 chunks: 0–499, 500–999, 1000–1049
        let messages = makeMessages(1050)

        try await store.saveMessages(messages, toThreadId: threadId)
        let (loaded, hasMore) = try await store.loadMessages(fromThreadId: threadId, as: TestMessage.self)

        // Last chunk = messages 1000–1049 (50 messages)
        #expect(loaded.count == 50)
        #expect(hasMore == true)
        #expect(loaded.first?.text == "msg_1000")
        #expect(loaded.last?.text == "msg_1049")
    }

    @Test("loadMessages on empty thread returns empty + hasMore false")
    func lazyLoadEmpty() async throws {
        let store = try makeStore()
        let threadId = try await store.createThread(title: "Empty")

        let (loaded, hasMore) = try await store.loadMessages(fromThreadId: threadId, as: TestMessage.self)

        #expect(loaded.isEmpty)
        #expect(hasMore == false)
    }

    // MARK: - Pagination

    @Test("loadMoreMessages walks backwards through chunks")
    func paginationWalkBack() async throws {
        let store = try makeStore()
        let threadId = try await store.createThread(title: "Paginate")
        // 3 chunks: 0 (500 msgs), 1 (500 msgs), 2 (100 msgs)
        let messages = makeMessages(1100)
        try await store.saveMessages(messages, toThreadId: threadId)

        // Step 1: open thread — get last chunk (index 2, 100 msgs)
        let (_, _) = try await store.loadMessages(fromThreadId: threadId, as: TestMessage.self)
        let lastIndex = try await store.lastChunkIndex(forThreadId: threadId)
        #expect(lastIndex == 2)

        // Step 2: scroll up — load chunk 1 (500 msgs)
        let (chunk1, hasMore1, newIndex1) = try await store.loadMoreMessages(
            fromThreadId: threadId,
            currentOldestChunkIndex: 2,
            as: TestMessage.self
        )
        #expect(chunk1.count == 500)
        #expect(hasMore1 == true)
        #expect(newIndex1 == 1)
        #expect(chunk1.first?.text == "msg_500")

        // Step 3: scroll up again — load chunk 0 (500 msgs)
        let (chunk0, hasMore0, newIndex0) = try await store.loadMoreMessages(
            fromThreadId: threadId,
            currentOldestChunkIndex: 1,
            as: TestMessage.self
        )
        #expect(chunk0.count == 500)
        #expect(hasMore0 == false) // chunk 0 is the oldest
        #expect(newIndex0 == 0)
        #expect(chunk0.first?.text == "msg_0")
    }

    @Test("loadMoreMessages at oldest chunk returns empty + hasMore false")
    func paginationAtOldest() async throws {
        let store = try makeStore()
        let threadId = try await store.createThread(title: "PaginateOldest")
        try await store.saveMessages(makeMessages(300), toThreadId: threadId)

        // Only one chunk (index 0) — calling loadMore from it should return nothing
        let (msgs, hasMore, newIndex) = try await store.loadMoreMessages(
            fromThreadId: threadId,
            currentOldestChunkIndex: 0,
            as: TestMessage.self
        )

        #expect(msgs.isEmpty)
        #expect(hasMore == false)
        #expect(newIndex == 0)
    }

    // MARK: - Delete Thread

    @Test("deleteThread removes all chunks")
    func deleteThreadRemovesChunks() async throws {
        let store = try makeStore()
        let threadId = try await store.createThread(title: "ToDelete")
        try await store.saveMessages(makeMessages(1200), toThreadId: threadId)

        try await store.deleteThread(id: threadId)

        // Thread should be gone from list
        let threads = try await store.loadThreads()
        #expect(!threads.contains(where: { $0.id == threadId }))

        // All messages should be gone
        let remaining = try await store.loadAllMessages(fromThreadId: threadId, as: TestMessage.self)
        #expect(remaining.isEmpty)
    }

    // MARK: - deleteOldMessages

    @Test("deleteOldMessages trims from the front")
    func deleteOldMessagesTrimsFront() async throws {
        let store = try makeStore()
        let threadId = try await store.createThread(title: "Trim")
        let messages = makeMessages(10)
        try await store.saveMessages(messages, toThreadId: threadId)

        try await store.deleteOldMessages(count: 3, fromThreadId: threadId, as: TestMessage.self)

        let remaining = try await store.loadAllMessages(fromThreadId: threadId, as: TestMessage.self)
        #expect(remaining.count == 7)
        #expect(remaining.first?.text == "msg_3") // first 3 removed
    }

    @Test("deleteOldMessages with count > total removes all")
    func deleteOldMessagesAll() async throws {
        let store = try makeStore()
        let threadId = try await store.createThread(title: "TrimAll")
        try await store.saveMessages(makeMessages(5), toThreadId: threadId)

        try await store.deleteOldMessages(count: 100, fromThreadId: threadId, as: TestMessage.self)

        let remaining = try await store.loadAllMessages(fromThreadId: threadId, as: TestMessage.self)
        #expect(remaining.isEmpty)
    }

    @Test("deleteOldMessages re-chunks correctly across chunk boundary")
    func deleteOldMessagesReChunks() async throws {
        let store = try makeStore()
        let threadId = try await store.createThread(title: "ReChunk")
        // 2 chunks: 500 + 200 = 700 messages
        let messages = makeMessages(700)
        try await store.saveMessages(messages, toThreadId: threadId)

        // Remove 600 — crosses chunk boundary, result = 100 messages in 1 chunk
        try await store.deleteOldMessages(count: 600, fromThreadId: threadId, as: TestMessage.self)

        let remaining = try await store.loadAllMessages(fromThreadId: threadId, as: TestMessage.self)
        #expect(remaining.count == 100)
        #expect(remaining.first?.text == "msg_600")

        // After re-chunk, only 1 chunk should exist → hasMore = false
        let (_, hasMore) = try await store.loadMessages(fromThreadId: threadId, as: TestMessage.self)
        #expect(hasMore == false)
    }

    // MARK: - Overwrite

    @Test("saveMessages overwrites previous history")
    func overwriteHistory() async throws {
        let store = try makeStore()
        let threadId = try await store.createThread(title: "Overwrite")

        try await store.saveMessages(makeMessages(600), toThreadId: threadId)
        try await store.saveMessages(makeMessages(10), toThreadId: threadId)

        let loaded = try await store.loadAllMessages(fromThreadId: threadId, as: TestMessage.self)
        #expect(loaded.count == 10)
    }

    // MARK: - Thread isolation

    @Test("Two threads do not share chunks")
    func threadIsolation() async throws {
        let store = try makeStore()
        let threadA = try await store.createThread(title: "A")
        let threadB = try await store.createThread(title: "B")

        let msgsA = makeMessages(5)
        let msgsB = makeMessages(3)
        try await store.saveMessages(msgsA, toThreadId: threadA)
        try await store.saveMessages(msgsB, toThreadId: threadB)

        let loadedA = try await store.loadAllMessages(fromThreadId: threadA, as: TestMessage.self)
        let loadedB = try await store.loadAllMessages(fromThreadId: threadB, as: TestMessage.self)

        #expect(loadedA.count == 5)
        #expect(loadedB.count == 3)
        #expect(loadedA == msgsA)
        #expect(loadedB == msgsB)
    }
}
