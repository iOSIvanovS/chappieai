// ThreadStoreOlderChunksTests.swift
// ChappieCoreTests
//
// Regression: the chat window holds only the last chunk, so right after a chunk rollover the
// model context was starved (512 messages stored, 10 sent). loadOlderChunks tops the window up.

import Testing
import Foundation
@testable import ChappieCore

@Suite("ThreadStore older chunks for model context")
struct ThreadStoreOlderChunksTests {

    private func seeded(count: Int) async throws -> (ThreadStore, UUID) {
        let storage = try SQLiteStorage(inMemory: true)
        let store = ThreadStore(dataStore: storage)
        let id = try await store.createThread(title: "T")
        try await store.replaceAllMessages(Array(0..<count), toThreadId: id)
        return (store, id)
    }

    @Test("Rollover: 512 messages, window holds 12, 30 needed -> previous chunk is loaded")
    func loadsPreviousChunkAfterRollover() async throws {
        let (store, id) = try await seeded(count: 512)
        let window = try await store.loadMessages(fromThreadId: id, as: Int.self)
        #expect(window.messages.count == 12)
        #expect(window.hasMore)
        let last = try #require(try await store.lastChunkIndex(forThreadId: id))

        let result = try await store.loadOlderChunks(
            fromThreadId: id,
            currentOldestChunkIndex: last,
            alreadyEligible: window.messages.count,
            needed: 31,
            as: Int.self,
            isEligible: { _ in true }
        )

        #expect(result.messages.count == 500)
        #expect(result.messages + window.messages == Array(0..<512))
        #expect(result.newOldestChunkIndex == last - 1)
        #expect(!result.hasMore)
    }

    @Test("Enough messages already: nothing is loaded")
    func nothingWhenEnough() async throws {
        let (store, id) = try await seeded(count: 700)
        let window = try await store.loadMessages(fromThreadId: id, as: Int.self)
        let last = try #require(try await store.lastChunkIndex(forThreadId: id))

        let result = try await store.loadOlderChunks(
            fromThreadId: id,
            currentOldestChunkIndex: last,
            alreadyEligible: window.messages.count,
            needed: 31,
            as: Int.self,
            isEligible: { _ in true }
        )

        #expect(result.messages.isEmpty)
        #expect(result.newOldestChunkIndex == last)
    }

    @Test("Ineligible messages do not count: more chunks are loaded until enough eligible ones")
    func ineligibleDoNotCount() async throws {
        let (store, id) = try await seeded(count: 1012)
        let window = try await store.loadMessages(fromThreadId: id, as: Int.self)
        #expect(window.messages.count == 12)
        let last = try #require(try await store.lastChunkIndex(forThreadId: id))

        // Only multiples of 500 are eligible: the window (1000...1011) holds one (1000), so
        // needing 3 forces the loader through both older chunks (500 and 0).
        let result = try await store.loadOlderChunks(
            fromThreadId: id,
            currentOldestChunkIndex: last,
            alreadyEligible: window.messages.filter { $0 % 500 == 0 }.count,
            needed: 3,
            as: Int.self,
            isEligible: { $0 % 500 == 0 }
        )

        #expect(result.messages.count == 1000)
        #expect(result.newOldestChunkIndex == last - 2)
        #expect(!result.hasMore)
    }

    @Test("Single chunk: nothing to load, no crash")
    func singleChunk() async throws {
        let (store, id) = try await seeded(count: 40)
        let last = try #require(try await store.lastChunkIndex(forThreadId: id))

        let result = try await store.loadOlderChunks(
            fromThreadId: id,
            currentOldestChunkIndex: last,
            alreadyEligible: 40,
            needed: 5000,
            as: Int.self,
            isEligible: { _ in true }
        )

        #expect(result.messages.isEmpty)
        #expect(result.newOldestChunkIndex == last)
    }
}
