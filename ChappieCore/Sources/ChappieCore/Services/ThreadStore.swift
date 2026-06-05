// ThreadStore.swift
// ChappieCore
//
// Actor for CRUD operations on threads via ChappieDataStore.
// No SwiftData imports here — all persistence goes through ChappieDataStore.
//
// STORAGE LAYOUT:
// - Relation.threads           → [ThreadPayload]   (thread list, metadata, settings)
// - Relation.threadMessages(id) → raw JSON Data    (per-thread messages, loaded on demand)
//
// Messages are stored as raw JSON Data (saveRawData/loadRawData) to avoid double-encoding.
// The caller encodes [T] → Data via JSONEncoder; DataStore stores Data as-is.
//
// CACHING:
// cachedThreads holds the thread list in RAM after first load.
// loadThreads() is served from cache — no DataStore hit on warm calls.
// loadMessages() always hits DataStore — per-thread, accessed only when thread is selected.
// All writes call refreshCache() to keep the thread list consistent.
//
// CODABLE COMPATIBILITY (see DataStore.swift for full rules):
//   1. Never rename ThreadPayload fields without CodingKeys.
//   2. Never remove fields — mark optional with a default instead.
//   3. New fields must have a default value so old records decode cleanly.

import Foundation

// MARK: - ThreadPayload

/// Codable struct stored inside [ThreadPayload] under Relation.threads.
/// Replaces the legacy @Model ThreadEntity class.
///
/// WHY STRUCT, NOT @MODEL: plain Codable — no SwiftData migrations ever needed.
public struct ThreadPayload: Codable, Sendable, Identifiable {

    public let id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var settingsJSON: Data
    public var projectBindingsJSON: Data

    public init(
        id: UUID = UUID(),
        title: String,
        settings: ThreadSettings = ThreadSettings(),
        projectIds: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.settingsJSON = (try? JSONEncoder().encode(settings)) ?? Data()
        self.projectBindingsJSON = (try? JSONEncoder().encode(projectIds)) ?? Data()
    }

    // CodingKeys guard against future renames.
    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt           = "created_at"
        case updatedAt           = "updated_at"
        case settingsJSON        = "settings_json"
        case projectBindingsJSON = "project_bindings_json"
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

    public var sizeMB: Double { Double(sizeBytes) / 1_048_576 }
}

// MARK: - ThreadStore

/// Actor for managing threads via ChappieDataStore.
/// All methods are isolated in the actor — safe concurrent access is guaranteed.
public actor ThreadStore {

    private let dataStore: ChappieDataStore
    private var cachedThreads: [ThreadMetadata]? = nil

    public init(dataStore: ChappieDataStore) {
        self.dataStore = dataStore
    }

    // MARK: - Private helpers

    private func loadPayloads() async throws -> [ThreadPayload] {
        return (try await dataStore.load(.threads)) ?? []
    }

    private func savePayloads(_ payloads: [ThreadPayload]) async throws {
        try await dataStore.save(payloads, for: .threads)
    }

    private func messagesRelation(for threadId: UUID) -> ChappieDataStore.Relation {
        .threadMessages(threadId)
    }

    private func refreshCache() async throws {
        let payloads = try await loadPayloads()
        cachedThreads = payloads
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { ThreadMetadata(from: $0) }
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

    // MARK: - Messages (Generic)

    /// Saves the full message history for a thread.
    /// Encodes [T] → Data and stores as raw bytes to avoid double-encoding.
    public func saveMessages<T: Codable>(_ messages: [T], toThreadId threadId: UUID) async throws {
        let data = try JSONEncoder().encode(messages)
        try await dataStore.saveRawData(data, for: messagesRelation(for: threadId))

        // Update updatedAt in the thread payload
        var payloads = try await loadPayloads()
        if let idx = payloads.firstIndex(where: { $0.id == threadId }) {
            payloads[idx].updatedAt = Date()
            try await savePayloads(payloads)
        }
        try await refreshCache()
    }

    /// Loads messages for a thread. Returns [] if not found or decode fails.
    public func loadMessages<T: Codable>(fromThreadId threadId: UUID, as type: T.Type) async throws -> [T] {
        guard let data = try await dataStore.loadRawData(messagesRelation(for: threadId)) else {
            return []
        }
        do {
            return try JSONDecoder().decode([T].self, from: data)
        } catch {
            print("[ThreadStore] ⚠️ Failed to decode messages for thread \(threadId): \(error)")
            return []
        }
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

    // MARK: - Project Bindings

    public func loadProjectIds(forThreadId threadId: UUID) async throws -> [UUID] {
        let payloads = try await loadPayloads()
        guard let payload = payloads.first(where: { $0.id == threadId }),
              !payload.projectBindingsJSON.isEmpty,
              let ids = try? JSONDecoder().decode([UUID].self, from: payload.projectBindingsJSON)
        else { return [] }
        return ids
    }

    public func updateProjectBindings(_ projectIds: [UUID], forThreadId threadId: UUID) async throws {
        var payloads = try await loadPayloads()
        guard let idx = payloads.firstIndex(where: { $0.id == threadId }) else {
            print("[ThreadStore] ⚠️ Thread \(threadId) not found when updating project bindings")
            return
        }
        payloads[idx].projectBindingsJSON = (try? JSONEncoder().encode(projectIds)) ?? payloads[idx].projectBindingsJSON
        payloads[idx].updatedAt = Date()
        try await savePayloads(payloads)
        try await refreshCache()
        print("[ThreadStore] ✅ Updated project bindings for thread \(threadId): \(projectIds.count) projects")
    }

    public func addProject(id projectId: UUID, toThreadId threadId: UUID) async throws {
        var payloads = try await loadPayloads()
        guard let idx = payloads.firstIndex(where: { $0.id == threadId }) else { return }

        var ids: [UUID] = []
        if !payloads[idx].projectBindingsJSON.isEmpty {
            ids = (try? JSONDecoder().decode([UUID].self, from: payloads[idx].projectBindingsJSON)) ?? []
        }

        guard !ids.contains(projectId) else {
            print("[ThreadStore] ℹ️ Project \(projectId) already in thread \(threadId)")
            return
        }

        ids.append(projectId)
        payloads[idx].projectBindingsJSON = (try? JSONEncoder().encode(ids)) ?? payloads[idx].projectBindingsJSON
        payloads[idx].updatedAt = Date()
        try await savePayloads(payloads)
        try await refreshCache()
        print("[ThreadStore] ✅ Project \(projectId) added to thread \(threadId)")
    }

    public func removeProject(id projectId: UUID, fromThreadId threadId: UUID) async throws {
        var payloads = try await loadPayloads()
        guard let idx = payloads.firstIndex(where: { $0.id == threadId }) else { return }

        var ids: [UUID] = []
        if !payloads[idx].projectBindingsJSON.isEmpty {
            ids = (try? JSONDecoder().decode([UUID].self, from: payloads[idx].projectBindingsJSON)) ?? []
        }

        let countBefore = ids.count
        ids.removeAll { $0 == projectId }
        guard ids.count < countBefore else { return }

        payloads[idx].projectBindingsJSON = (try? JSONEncoder().encode(ids)) ?? payloads[idx].projectBindingsJSON
        payloads[idx].updatedAt = Date()
        try await savePayloads(payloads)
        try await refreshCache()
        print("[ThreadStore] ✅ Project \(projectId) removed from thread \(threadId)")
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
        // Delete the messages record for this thread too
        try await dataStore.delete(messagesRelation(for: threadId))
        try await refreshCache()
        print("[ThreadStore] 🗑 Thread '\(title)' deleted")
    }

    // MARK: - Memory Management

    public func loadMemoryInfo() async throws -> [ThreadMemoryInfo] {
        let payloads = try await loadPayloads()
        var result: [ThreadMemoryInfo] = []

        for payload in payloads.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let rawData = try await dataStore.loadRawData(messagesRelation(for: payload.id))
            let sizeBytes = rawData?.count ?? 0

            let count: Int
            if let data = rawData,
               let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                count = array.count
            } else {
                count = 0
            }

            result.append(ThreadMemoryInfo(
                threadId: payload.id,
                title: payload.title,
                messageCount: count,
                sizeBytes: sizeBytes
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

        var messages: [T] = try await loadMessages(fromThreadId: threadId, as: type)
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

// MARK: - ThreadMetadata init from ThreadPayload

extension ThreadMetadata {

    init(from payload: ThreadPayload) {
        self.id = payload.id
        self.title = payload.title
        self.createdAt = payload.createdAt
        self.updatedAt = payload.updatedAt

        if !payload.projectBindingsJSON.isEmpty,
           let ids = try? JSONDecoder().decode([UUID].self, from: payload.projectBindingsJSON) {
            self.projectIds = ids
        } else {
            self.projectIds = []
        }

        if !payload.settingsJSON.isEmpty,
           let settings = try? JSONDecoder().decode(ThreadSettings.self, from: payload.settingsJSON) {
            self.settings = settings
        } else {
            self.settings = ThreadSettings()
        }
    }
}
