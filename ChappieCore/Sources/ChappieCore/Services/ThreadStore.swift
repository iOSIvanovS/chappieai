// ThreadStore.swift
// ChappieCore
//
// Actor for CRUD operations on threads via ChappieStorage protocol.
// No SwiftData imports here — all persistence goes through the storage abstraction.
//
// STORAGE LAYOUT:
// - .threads                → [ThreadPayload]  (thread list, metadata, settings)
// - .threadMessages(id)     → raw JSON Data    (per-thread messages, loaded on demand)
//
// Messages are stored as raw JSON Data (saveRawData/loadRawData) to avoid double-encoding.
//
// CACHING:
// cachedThreads holds the thread list in RAM after first load.
// loadThreads() is served from cache — no storage hit on warm calls.
// loadMessages() always hits storage — per-thread, accessed only when thread is selected.
// All writes call refreshCache() to keep the thread list consistent.

import Foundation

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

    // MARK: - Private helpers

    private func loadPayloads() async throws -> [ThreadPayload] {
        return (try await dataStore.load(.threads)) ?? []
    }

    private func savePayloads(_ payloads: [ThreadPayload]) async throws {
        try await dataStore.save(payloads, for: .threads)
    }

    private func messagesRelation(for threadId: UUID) -> ChappieStorageRelation {
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
    public func saveMessages<T: Codable>(_ messages: [T], toThreadId threadId: UUID) async throws {
        let data = try JSONEncoder().encode(messages)
        try await dataStore.saveRawData(data, for: messagesRelation(for: threadId))

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

    // MARK: - Starter plan enforcement

    /// Resets terminal access to .none across ALL threads.
    /// Called when a Starter license is activated — Starter plan forbids terminal access.
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
