// ThreadStore+Chunks.swift
// ChappieCore
//
// Chunked message storage: read/write helpers + public save/load API.
//
// STRATEGY: messages split into THREAD_CHUNK_SIZE (500) rows.
// Key format: "thread_messages_chunk.<UUID>.<index>" (integer, not zero-padded).
// Lazy loading: loadMessages() returns only the last chunk (fast open).
// Full load: loadAllMessages() assembles all chunks (AI context, export).

import Foundation

// MARK: - Array chunking helper

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - ThreadStore + Chunks

extension ThreadStore {

    // MARK: Chunk key helpers

    func chunkRelation(_ threadId: UUID, _ index: Int) -> ChappieStorageRelation {
        .threadMessagesChunk(threadId, index)
    }

    /// Returns sorted chunk indices currently stored for a thread.
    func chunkIndices(for threadId: UUID) async throws -> [Int] {
        let prefix = ChappieStorageRelation.chunkPrefix(for: threadId)
        let allKeys = try await dataStore.keys(withPrefix: prefix)
        return allKeys.compactMap { key -> Int? in
            guard let lastDot = key.lastIndex(of: ".") else { return nil }
            let indexStr = String(key[key.index(after: lastDot)...])
            return Int(indexStr)
        }.sorted()
    }

    // MARK: Chunk read/write

    /// Writes `messages` as chunks starting at chunk `fromChunk`, replacing chunks with an index
    /// >= fromChunk in ONE transaction (a crash or error leaves the old data intact).
    /// Chunks below `fromChunk` are never touched.
    func writeChunks<T: Codable>(_ messages: [T], toThreadId threadId: UUID, fromChunk: Int = 0) async throws {
        let prefix = ChappieStorageRelation.chunkPrefix(for: threadId)
        let encoder = JSONEncoder()
        let payloads = try messages
            .chunked(into: THREAD_CHUNK_SIZE)
            .filter { !$0.isEmpty }
            .map { try encoder.encode($0) }
        try await dataStore.replaceIndexedRecords(prefix: prefix, fromIndex: fromChunk, payloads: payloads)
    }

    /// Bumps `updatedAt` of the thread and refreshes the metadata cache.
    private func touchThread(_ threadId: UUID) async throws {
        var payloads = try await loadPayloads()
        if let idx = payloads.firstIndex(where: { $0.id == threadId }) {
            payloads[idx].updatedAt = Date()
            try await savePayloads(payloads)
        }
        try await refreshCache()
    }

    /// Reads all chunks and assembles the full message array.
    func readAllChunks<T: Codable>(threadId: UUID, as type: T.Type) async throws -> [T] {
        let indices = try await chunkIndices(for: threadId)
        guard !indices.isEmpty else { return [] }

        var result: [T] = []
        result.reserveCapacity(indices.count * THREAD_CHUNK_SIZE)

        for index in indices {
            guard let data = try await dataStore.loadRawData(chunkRelation(threadId, index)) else { continue }
            let chunk = try JSONDecoder().decode([T].self, from: data)
            result.append(contentsOf: chunk)
        }
        return result
    }

    /// Reads only the last N chunks — for lazy loading on thread open.
    func readLastChunks<T: Codable>(threadId: UUID, count: Int, as type: T.Type) async throws -> [T] {
        let indices = try await chunkIndices(for: threadId)
        guard !indices.isEmpty else { return [] }

        let lastIndices = Array(indices.suffix(count))
        var result: [T] = []

        for index in lastIndices {
            guard let data = try await dataStore.loadRawData(chunkRelation(threadId, index)) else { continue }
            let chunk = try JSONDecoder().decode([T].self, from: data)
            result.append(contentsOf: chunk)
        }
        return result
    }

    // MARK: Public API

    /// DESTRUCTIVE: replaces the ENTIRE stored history of a thread with `messages`.
    /// Only pass the complete history here (import, "clear memory", delete-old-messages).
    /// For normal saves of a lazily loaded window use `saveLoadedMessages`.
    public func replaceAllMessages<T: Codable>(_ messages: [T], toThreadId threadId: UUID) async throws {
        try await writeChunks(messages, toThreadId: threadId, fromChunk: 0)
        try await touchThread(threadId)
    }

    /// Saves the in-memory window of a thread. `messages` must be exactly the messages from
    /// chunk `fromChunk` to the end of the thread; older chunks stay on disk untouched.
    /// WHY: the UI only loads the last chunk on open — rewriting from 0 would erase older history.
    public func saveLoadedMessages<T: Codable>(
        _ messages: [T],
        toThreadId threadId: UUID,
        fromChunk: Int
    ) async throws {
        try await writeChunks(messages, toThreadId: threadId, fromChunk: max(0, fromChunk))
        try await touchThread(threadId)
    }

    /// Loads the last chunk only — fast O(1) open regardless of history size.
    /// Returns (messages, hasMore) — hasMore = true means older chunks exist.
    public func loadMessages<T: Codable>(
        fromThreadId threadId: UUID,
        as type: T.Type
    ) async throws -> (messages: [T], hasMore: Bool) {
        let indices = try await chunkIndices(for: threadId)
        guard !indices.isEmpty else { return ([], false) }

        let hasMore = indices.count > 1
        let lastMessages = try await readLastChunks(threadId: threadId, count: 1, as: type)
        return (lastMessages, hasMore)
    }

    /// Loads ALL messages — used for AI context building and export.
    public func loadAllMessages<T: Codable>(
        fromThreadId threadId: UUID,
        as type: T.Type
    ) async throws -> [T] {
        let indices = try await chunkIndices(for: threadId)
        guard !indices.isEmpty else { return [] }
        return try await readAllChunks(threadId: threadId, as: type)
    }

    /// Loads the previous chunk when user scrolls to top.
    /// Returns (olderMessages, hasMore, newOldestChunkIndex).
    public func loadMoreMessages<T: Codable>(
        fromThreadId threadId: UUID,
        currentOldestChunkIndex: Int,
        as type: T.Type
    ) async throws -> (messages: [T], hasMore: Bool, newOldestChunkIndex: Int) {
        let indices = try await chunkIndices(for: threadId)
        guard let pos = indices.firstIndex(of: currentOldestChunkIndex), pos > 0 else {
            return ([], false, currentOldestChunkIndex)
        }

        let prevIndex = indices[pos - 1]
        guard let data = try await dataStore.loadRawData(chunkRelation(threadId, prevIndex)) else {
            return ([], false, currentOldestChunkIndex)
        }

        let chunk = try JSONDecoder().decode([T].self, from: data)
        let hasMore = pos - 1 > 0
        return (chunk, hasMore, prevIndex)
    }

    /// Returns the chunk index of the last (most recent) chunk, or nil if no chunks exist.
    public func lastChunkIndex(forThreadId threadId: UUID) async throws -> Int? {
        let indices = try await chunkIndices(for: threadId)
        return indices.last
    }

    /// Deletes the oldest `count` messages from a thread by rewriting all chunks.
    public func deleteOldMessages<T: Codable>(
        count: Int,
        fromThreadId threadId: UUID,
        as type: T.Type
    ) async throws {
        guard count > 0 else { return }

        var messages: [T] = try await loadAllMessages(fromThreadId: threadId, as: type)
        guard !messages.isEmpty else { return }

        let toDelete = min(count, messages.count)
        messages.removeFirst(toDelete)

        try await replaceAllMessages(messages, toThreadId: threadId)
        print("[ThreadStore] 🗑 Deleted \(toDelete) old messages from thread \(threadId)")
    }
}
