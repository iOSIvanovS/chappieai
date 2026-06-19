// ThreadStore.swift
// ChappieCore
//
// Actor for CRUD operations on threads via ChappieStorage protocol.
//
// STORAGE LAYOUT:
// - .threads                              → [ThreadPayload]  (thread list, metadata, settings)
// - .threadMessagesChunk(id, index)       → [ChatMessage]    (500-message chunks, zero-padded index)
//
// CHUNKING STRATEGY:
// Messages are split into chunks of CHUNK_SIZE (500) messages each.
// Key format: "thread_messages_chunk.<UUID>.000000", ".000001", etc.
// Zero-padding ensures lexicographic sort == chronological sort.
//
// LAZY LOADING:
// loadMessages() returns only the LAST chunk — what the user sees immediately.
// loadMoreMessages() loads the previous chunk — called when user scrolls to top.
// This keeps thread open time O(1) regardless of total history size.

import Foundation

// MARK: - Constants

private let CHUNK_SIZE = 500

// MARK: - ThreadPayload

/// Codable struct stored inside [ThreadPayload] under .threads relation.
public struct ThreadPayload: Codable, Sendable, Identifiable {

    public let id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var settingsJSON: Data
    /// Legacy field — kept for Codable compatibility with old records. Not written by new code.
    public var projectBindingsJSON: Data
    /// Thread-scoped projects with absolute paths. Default Data() for old records.
    public var projectsJSON: Data

    public init(
        id: UUID = UUID(),
        title: String,
        settings: ThreadSettings = ThreadSettings(),
        projects: [ThreadProjectEntry] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.settingsJSON = (try? JSONEncoder().encode(settings)) ?? Data()
        self.projectBindingsJSON = Data()
        self.projectsJSON = (try? JSONEncoder().encode(projects)) ?? Data()
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt           = "created_at"
        case updatedAt           = "updated_at"
        case settingsJSON        = "settings_json"
        case projectBindingsJSON = "project_bindings_json"
        case projectsJSON        = "projects_json"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = try c.decode(UUID.self, forKey: .id)
        title        = try c.decode(String.self, forKey: .title)
        createdAt    = try c.decode(Date.self, forKey: .createdAt)
        updatedAt    = try c.decode(Date.self, forKey: .updatedAt)
        settingsJSON = try c.decodeIfPresent(Data.self, forKey: .settingsJSON) ?? Data()
        projectBindingsJSON = try c.decodeIfPresent(Data.self, forKey: .projectBindingsJSON) ?? Data()
        projectsJSON = try c.decodeIfPresent(Data.self, forKey: .projectsJSON) ?? Data()
    }
}

// MARK: - Thread Memory Info

/// Snapshot of a thread's memory footprint — used by MemoryManagementView.
public struct ThreadMemoryInfo: Sendable, Identifiable {
    public var id: UUID { threadId }
    public let threadId: UUID
    public let title: String
    public let messageCount: Int
    public let sizeBytes: Int
    public let chunkCount: Int

    public var sizeMB: Double { Double(sizeBytes) / 1_048_576 }
}

// MARK: - ThreadStore

/// Actor for managing threads via ChappieStorage.
public actor ThreadStore {

    private let dataStore: any ChappieStorage
    private var cachedThreads: [ThreadMetadata]? = nil

    public init(dataStore: any ChappieStorage) {
        self.dataStore = dataStore
    }

    // MARK: - Private: Thread list helpers

    private func loadPayloads() async throws -> [ThreadPayload] {
        return (try await dataStore.load(.threads)) ?? []
    }

    private func savePayloads(_ payloads: [ThreadPayload]) async throws {
        try await dataStore.save(payloads, for: .threads)
    }

    private func refreshCache() async throws {
        let payloads = try await loadPayloads()
        cachedThreads = payloads
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { ThreadMetadata(from: $0) }
    }

    // MARK: - Private: Chunk key helpers

    private func chunkRelation(_ threadId: UUID, _ index: Int) -> ChappieStorageRelation {
        .threadMessagesChunk(threadId, index)
    }

    /// Returns sorted chunk indices currently stored for a thread.
    private func chunkIndices(for threadId: UUID) async throws -> [Int] {
        let prefix = ChappieStorageRelation.chunkPrefix(for: threadId)
        let allKeys = try await dataStore.keys(withPrefix: prefix)
        return allKeys.compactMap { key -> Int? in
            guard let lastDot = key.lastIndex(of: ".") else { return nil }
            let indexStr = String(key[key.index(after: lastDot)...])
            return Int(indexStr)
        }.sorted()
    }

    // MARK: - Private: Chunk read/write

    /// Writes all messages as chunks, replacing any existing chunks.
    private func writeChunks<T: Codable>(_ messages: [T], toThreadId threadId: UUID) async throws {
        let prefix = ChappieStorageRelation.chunkPrefix(for: threadId)
        try await dataStore.deleteByPrefix(prefix)

        let chunks = messages.chunked(into: CHUNK_SIZE)
        for (index, chunk) in chunks.enumerated() {
            let data = try JSONEncoder().encode(chunk)
            try await dataStore.saveRawData(data, for: chunkRelation(threadId, index))
        }
    }

    /// Reads all chunks and assembles the full message array.
    private func readAllChunks<T: Codable>(threadId: UUID, as type: T.Type) async throws -> [T] {
        let indices = try await chunkIndices(for: threadId)
        guard !indices.isEmpty else { return [] }

        var result: [T] = []
        result.reserveCapacity(indices.count * CHUNK_SIZE)

        for index in indices {
            guard let data = try await dataStore.loadRawData(chunkRelation(threadId, index)) else { continue }
            let chunk = try JSONDecoder().decode([T].self, from: data)
            result.append(contentsOf: chunk)
        }
        return result
    }

    /// Reads only the last N chunks — for lazy loading on thread open.
    private func readLastChunks<T: Codable>(threadId: UUID, count: Int, as type: T.Type) async throws -> [T] {
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

    // MARK: - Create

    public func createThread(
        title: String,
        settings: ThreadSettings = ThreadSettings()
    ) async throws -> UUID {
        var payloads = try await loadPayloads()
        let thread = ThreadPayload(title: title, settings: settings)
        payloads.append(thread)
        try await savePayloads(payloads)
        try await refreshCache()
        print("[ThreadStore] ✅ Created thread '\(title)' (id: \(thread.id))")
        return thread.id
    }

    // MARK: - Load

    public func loadThreads() async throws -> [ThreadMetadata] {
        if let cached = cachedThreads { return cached }
        try await refreshCache()
        return cachedThreads ?? []
    }

    // MARK: - Messages: Save

    /// Saves the full message history for a thread as chunks.
    public func saveMessages<T: Codable>(_ messages: [T], toThreadId threadId: UUID) async throws {
        try await writeChunks(messages, toThreadId: threadId)

        var payloads = try await loadPayloads()
        if let idx = payloads.firstIndex(where: { $0.id == threadId }) {
            payloads[idx].updatedAt = Date()
            try await savePayloads(payloads)
        }
        try await refreshCache()
    }

    // MARK: - Messages: Load (lazy — last chunk only)

    /// Loads the last chunk of messages for a thread (fast O(1) open regardless of history size).
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

    /// Loads ALL messages for a thread — used for AI context building and export.
    public func loadAllMessages<T: Codable>(
        fromThreadId threadId: UUID,
        as type: T.Type
    ) async throws -> [T] {
        let indices = try await chunkIndices(for: threadId)
        guard !indices.isEmpty else { return [] }
        return try await readAllChunks(threadId: threadId, as: type)
    }

    /// Loads the previous chunk for a thread — called when user scrolls to top.
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

    // MARK: - Settings

    public func updateSettings(_ settings: ThreadSettings, forThreadId threadId: UUID) async throws {
        var payloads = try await loadPayloads()
        guard let idx = payloads.firstIndex(where: { $0.id == threadId }) else { return }
        payloads[idx].settingsJSON = (try? JSONEncoder().encode(settings)) ?? payloads[idx].settingsJSON
        try await savePayloads(payloads)
        try await refreshCache()
    }

    public func loadSettings(forThreadId threadId: UUID) async throws -> ThreadSettings {
        let payloads = try await loadPayloads()
        guard let payload = payloads.first(where: { $0.id == threadId }),
              !payload.settingsJSON.isEmpty,
              let settings = try? JSONDecoder().decode(ThreadSettings.self, from: payload.settingsJSON)
        else { return ThreadSettings() }
        return settings
    }

    // MARK: - Starter plan enforcement

    /// Resets terminal access to .none across ALL threads.
    public func downgradeTerminalInAllThreads() async throws {
        var payloads = try await loadPayloads()
        var changed = false

        for idx in payloads.indices {
            guard !payloads[idx].settingsJSON.isEmpty,
                  var settings = try? JSONDecoder().decode(ThreadSettings.self, from: payloads[idx].settingsJSON),
                  settings.terminalAccess != .none
            else { continue }

            settings.terminalAccess = .none
            payloads[idx].settingsJSON = (try? JSONEncoder().encode(settings)) ?? payloads[idx].settingsJSON
            changed = true
        }

        guard changed else { return }
        try await savePayloads(payloads)
        try await refreshCache()
        print("[ThreadStore] ✅ Terminal access reset to .none in all threads (Starter plan)")
    }

    // MARK: - Thread-scoped Projects

    public func loadProjects(forThreadId threadId: UUID) async throws -> [ThreadProjectEntry] {
        let payloads = try await loadPayloads()
        guard let payload = payloads.first(where: { $0.id == threadId }),
              !payload.projectsJSON.isEmpty,
              let projects = try? JSONDecoder().decode([ThreadProjectEntry].self, from: payload.projectsJSON)
        else { return [] }
        return projects
    }

    public func addProject(_ entry: ThreadProjectEntry, toThreadId threadId: UUID) async throws {
        var payloads = try await loadPayloads()
        guard let idx = payloads.firstIndex(where: { $0.id == threadId }) else { return }

        var projects: [ThreadProjectEntry] = []
        if !payloads[idx].projectsJSON.isEmpty {
            projects = (try? JSONDecoder().decode([ThreadProjectEntry].self, from: payloads[idx].projectsJSON)) ?? []
        }

        guard !projects.contains(where: { $0.absolutePath == entry.absolutePath }) else {
            print("[ThreadStore] ℹ️ Project '\(entry.displayName)' already in thread (same path)")
            return
        }

        projects.append(entry)
        payloads[idx].projectsJSON = (try? JSONEncoder().encode(projects)) ?? payloads[idx].projectsJSON
        payloads[idx].updatedAt = Date()
        try await savePayloads(payloads)
        try await refreshCache()
        print("[ThreadStore] ✅ Project '\(entry.displayName)' added to thread \(threadId)")
    }

    public func removeProject(id projectId: UUID, fromThreadId threadId: UUID) async throws {
        var payloads = try await loadPayloads()
        guard let idx = payloads.firstIndex(where: { $0.id == threadId }) else { return }

        var projects: [ThreadProjectEntry] = []
        if !payloads[idx].projectsJSON.isEmpty {
            projects = (try? JSONDecoder().decode([ThreadProjectEntry].self, from: payloads[idx].projectsJSON)) ?? []
        }

        let before = projects.count
        projects.removeAll { $0.id == projectId }
        guard projects.count < before else { return }

        payloads[idx].projectsJSON = (try? JSONEncoder().encode(projects)) ?? payloads[idx].projectsJSON
        payloads[idx].updatedAt = Date()
        try await savePayloads(payloads)
        try await refreshCache()
        print("[ThreadStore] ✅ Project \(projectId) removed from thread \(threadId)")
    }

    public func updateProjectSettings(
        _ settings: ProjectSettings,
        projectId: UUID,
        threadId: UUID
    ) async throws {
        var payloads = try await loadPayloads()
        guard let tIdx = payloads.firstIndex(where: { $0.id == threadId }) else { return }

        var projects: [ThreadProjectEntry] = []
        if !payloads[tIdx].projectsJSON.isEmpty {
            projects = (try? JSONDecoder().decode([ThreadProjectEntry].self, from: payloads[tIdx].projectsJSON)) ?? []
        }

        guard let pIdx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[pIdx].settings = settings
        payloads[tIdx].projectsJSON = (try? JSONEncoder().encode(projects)) ?? payloads[tIdx].projectsJSON
        payloads[tIdx].updatedAt = Date()
        try await savePayloads(payloads)
        try await refreshCache()
        print("[ThreadStore] ✅ Settings updated for project \(projectId) in thread \(threadId)")
    }

    // MARK: - Rename

    public func renameThread(id threadId: UUID, title: String) async throws {
        var payloads = try await loadPayloads()
        guard let idx = payloads.firstIndex(where: { $0.id == threadId }) else { return }
        payloads[idx].title = title
        payloads[idx].updatedAt = Date()
        try await savePayloads(payloads)
        try await refreshCache()
    }

    // MARK: - Delete

    public func deleteThread(id threadId: UUID) async throws {
        var payloads = try await loadPayloads()
        guard let idx = payloads.firstIndex(where: { $0.id == threadId }) else { return }
        let title = payloads[idx].title
        payloads.remove(at: idx)
        try await savePayloads(payloads)

        // Delete all chunks atomically
        let prefix = ChappieStorageRelation.chunkPrefix(for: threadId)
        try await dataStore.deleteByPrefix(prefix)

        try await refreshCache()
        print("[ThreadStore] 🗑 Thread '\(title)' deleted")
    }

    // MARK: - Memory Management

    public func loadMemoryInfo() async throws -> [ThreadMemoryInfo] {
        let payloads = try await loadPayloads()
        var result: [ThreadMemoryInfo] = []

        for payload in payloads.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let indices = try await chunkIndices(for: payload.id)

            var totalSize = 0
            var totalCount = 0

            for index in indices {
                guard let data = try await dataStore.loadRawData(chunkRelation(payload.id, index)) else { continue }
                totalSize += data.count
                if let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                    totalCount += arr.count
                }
            }

            result.append(ThreadMemoryInfo(
                threadId: payload.id,
                title: payload.title,
                messageCount: totalCount,
                sizeBytes: totalSize,
                chunkCount: max(1, indices.count)
            ))
        }

        return result
    }

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

        try await saveMessages(messages, toThreadId: threadId)
        print("[ThreadStore] 🗑 Deleted \(toDelete) old messages from thread \(threadId)")
    }

    // MARK: - Default Provider (stub)

    public func loadDefaultProvider() async throws -> AIProvider? {
        return nil
    }
}

// MARK: - Array chunking helper

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - ThreadMetadata init from ThreadPayload

extension ThreadMetadata {

    init(from payload: ThreadPayload) {
        self.id = payload.id
        self.title = payload.title
        self.createdAt = payload.createdAt
        self.updatedAt = payload.updatedAt

        if !payload.projectsJSON.isEmpty,
           let entries = try? JSONDecoder().decode([ThreadProjectEntry].self, from: payload.projectsJSON) {
            self.projects = entries
        } else {
            self.projects = []
        }

        if !payload.settingsJSON.isEmpty,
           let settings = try? JSONDecoder().decode(ThreadSettings.self, from: payload.settingsJSON) {
            self.settings = settings
        } else {
            self.settings = ThreadSettings()
        }
    }
}
