// ThreadStore.swift
// ChappieCore
//
// Actor core: init, thread list CRUD (create/rename/delete), payload cache.
// Extensions handle chunks, projects, settings, and memory management.

import Foundation

// MARK: - Constants

let THREAD_CHUNK_SIZE = 500

// MARK: - ThreadPayload

/// Codable record stored under .threads relation as [ThreadPayload].
public struct ThreadPayload: Codable, Sendable, Identifiable {

    public let id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var settingsJSON: Data
    /// Legacy field — kept for Codable compatibility. Not written by new code.
    public var projectBindingsJSON: Data
    /// Thread-scoped projects with absolute paths. Defaults to Data() for old records.
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

// MARK: - ThreadMemoryInfo

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

    let dataStore: any ChappieStorage
    var cachedThreads: [ThreadMetadata]? = nil

    /// Damage found while reading the thread list, not yet shown to the user.
    var pendingIntegrityIssues: [StorageIntegrityIssue] = []
    /// Single in-flight repair: actor reentrancy would otherwise let two callers repair (and write) at once.
    var repairTask: Task<[ThreadPayload], Error>? = nil
    /// Title for a rebuilt thread that has no user message to take a title from (localized by the app).
    let recoveredThreadTitle: String

    public init(dataStore: any ChappieStorage, recoveredThreadTitle: String = "Recovered chat") {
        self.dataStore = dataStore
        self.recoveredThreadTitle = recoveredThreadTitle
    }

    // MARK: - Payload helpers (used by all extensions)

    /// Reads the thread list. A missing record is an empty list; an unreadable one is NOT silently
    /// treated as empty: the damaged blob is backed up, readable threads are salvaged one by one,
    /// threads that only survive as message chunks are rebuilt (see ThreadStore+Recovery), and an
    /// issue is queued for the UI (see `takeIntegrityIssues`).
    func loadPayloads() async throws -> [ThreadPayload] {
        guard let raw = try await dataStore.loadRawData(.threads) else { return [] }
        if let all = try? JSONDecoder().decode([ThreadPayload].self, from: raw) { return all }

        if let running = repairTask { return try await running.value }
        let task = Task { try await self.repairDamagedList(raw) }
        repairTask = task
        defer { repairTask = nil }
        return try await task.value
    }

    /// Hands over (and clears) the damage reports collected since the last call.
    public func takeIntegrityIssues() -> [StorageIntegrityIssue] {
        defer { pendingIntegrityIssues.removeAll() }
        return pendingIntegrityIssues
    }

    func savePayloads(_ payloads: [ThreadPayload]) async throws {
        try await dataStore.save(payloads, for: .threads)
    }

    func refreshCache() async throws {
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
