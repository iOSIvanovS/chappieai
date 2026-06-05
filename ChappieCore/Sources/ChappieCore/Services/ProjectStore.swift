// ProjectStore.swift
// ChappieCore
//
// Actor for CRUD operations on projects via ChappieDataStore.
// No SwiftData imports here — all persistence goes through ChappieDataStore.Relation.projects.
//
// STORAGE LAYOUT:
// All projects stored as [ProjectPayload] under Relation.projects.
// Bookmarks are stored separately under Relation.projectBookmark("<uuid>") —
// they are large binary blobs not worth loading with the list.
//
// CACHING:
// cachedProjects holds all projects in RAM after first load.
// loadProjects() / loadProject(id:) / loadProjects(ids:) are served from cache.
// loadBookmark() always hits DataStore — accessed rarely (only during FS sync).
// All writes call refreshCache() to keep the cache consistent.
//
// CODABLE COMPATIBILITY (see DataStore.swift for full rules):
//   1. Never rename ProjectPayload fields without CodingKeys.
//   2. Never remove fields — mark optional with a default instead.
//   3. New fields must have a default value so old records decode cleanly.

import Foundation

// MARK: - ProjectPayload

/// Codable struct stored inside [ProjectPayload] under Relation.projects.
/// Replaces the legacy @Model ProjectEntity class.
///
/// WHY STRUCT, NOT @MODEL: plain Codable — no SwiftData migrations ever needed.
public struct ProjectPayload: Codable, Sendable, Identifiable {

    public let id: UUID
    public var displayName: String
    public var createdAt: Date
    public var settingsJSON: Data

    public init(
        id: UUID = UUID(),
        displayName: String,
        settings: ProjectSettings = ProjectSettings()
    ) {
        self.id = id
        self.displayName = displayName
        self.createdAt = Date()
        self.settingsJSON = (try? JSONEncoder().encode(settings)) ?? Data()
    }

    // CodingKeys guard against future renames.
    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case createdAt   = "created_at"
        case settingsJSON = "settings_json"
    }
}

// MARK: - ProjectStore

/// Actor managing projects via ChappieDataStore.
public actor ProjectStore {

    private let dataStore: ChappieDataStore
    private var cachedProjects: [ProjectMetadata]? = nil

    public init(dataStore: ChappieDataStore) {
        self.dataStore = dataStore
    }

    // MARK: - Private helpers

    private func loadPayloads() async throws -> [ProjectPayload] {
        return (try await dataStore.load(.projects)) ?? []
    }

    private func savePayloads(_ payloads: [ProjectPayload]) async throws {
        try await dataStore.save(payloads, for: .projects)
    }

    private func bookmarkRelation(for projectId: UUID) -> ChappieDataStore.Relation {
        .projectBookmark(projectId)
    }

    private func refreshCache() async throws {
        let payloads = try await loadPayloads()
        cachedProjects = payloads
            .sorted { $0.createdAt > $1.createdAt }
            .map { ProjectMetadata(from: $0) }
    }

    private func getProjects() async throws -> [ProjectMetadata] {
        if let cached = cachedProjects { return cached }
        try await refreshCache()
        return cachedProjects ?? []
    }

    // MARK: - Create

    /// Adds a new project. Returns the new project's UUID.
    public func addProject(
        displayName: String,
        bookmarkData: Data,
        settings: ProjectSettings = ProjectSettings()
    ) async throws -> UUID {
        var payloads = try await loadPayloads()
        let project = ProjectPayload(displayName: displayName, settings: settings)
        payloads.append(project)
        try await savePayloads(payloads)
        // Store bookmark separately — large binary blob
        try await dataStore.save(bookmarkData, for: bookmarkRelation(for: project.id))
        try await refreshCache()
        print("[ProjectStore] ✅ Added project '\(displayName)' (id: \(project.id))")
        return project.id
    }

    // MARK: - Read

    public func loadProjects() async throws -> [ProjectMetadata] {
        return try await getProjects()
    }

    public func loadProject(id: UUID) async throws -> ProjectMetadata? {
        return try await getProjects().first(where: { $0.id == id })
    }

    public func loadProjects(ids: [UUID]) async throws -> [ProjectMetadata] {
        guard !ids.isEmpty else { return [] }
        let map = Dictionary(uniqueKeysWithValues: try await getProjects().map { ($0.id, $0) })
        return ids.compactMap { map[$0] }
    }

    /// Loads the security-scoped bookmark for a project.
    /// Always hits DataStore — bookmarks are large binary blobs, not worth caching.
    public func loadBookmark(forProjectId id: UUID) async throws -> Data? {
        return try await dataStore.load(bookmarkRelation(for: id))
    }

    // MARK: - Update

    public func updateSettings(_ settings: ProjectSettings, forProjectId projectId: UUID) async throws {
        var payloads = try await loadPayloads()
        guard let idx = payloads.firstIndex(where: { $0.id == projectId }) else { return }
        payloads[idx].settingsJSON = (try? JSONEncoder().encode(settings)) ?? payloads[idx].settingsJSON
        try await savePayloads(payloads)
        try await refreshCache()
        print("[ProjectStore] ✅ Updated settings for project \(projectId)")
    }

    public func updateBookmark(_ bookmarkData: Data, forProjectId projectId: UUID) async throws {
        try await dataStore.save(bookmarkData, for: bookmarkRelation(for: projectId))
        // No cache refresh needed — bookmark is not stored in ProjectMetadata
        print("[ProjectStore] ✅ Updated bookmark for project \(projectId)")
    }

    public func renameProject(id projectId: UUID, name: String) async throws {
        var payloads = try await loadPayloads()
        guard let idx = payloads.firstIndex(where: { $0.id == projectId }) else { return }
        payloads[idx].displayName = name
        try await savePayloads(payloads)
        try await refreshCache()
    }

    // MARK: - Delete

    /// Deletes a project and its bookmark.
    /// Threads that reference it will get an unresolvable UUID — UI handles gracefully.
    public func deleteProject(id projectId: UUID) async throws {
        var payloads = try await loadPayloads()
        guard let idx = payloads.firstIndex(where: { $0.id == projectId }) else { return }
        let name = payloads[idx].displayName
        payloads.remove(at: idx)
        try await savePayloads(payloads)
        try await dataStore.delete(bookmarkRelation(for: projectId))
        try await refreshCache()
        print("[ProjectStore] 🗑 Deleted project '\(name)'")
    }
}

// MARK: - ProjectMetadata init from ProjectPayload

extension ProjectMetadata {

    /// Creates ProjectMetadata from a ProjectPayload (inside actor only).
    init(from payload: ProjectPayload) {
        self.id = payload.id
        self.displayName = payload.displayName
        self.createdAt = payload.createdAt
        self.isUnavailable = false

        if !payload.settingsJSON.isEmpty,
           let decoded = try? JSONDecoder().decode(ProjectSettings.self, from: payload.settingsJSON) {
            self.settings = decoded
        } else {
            self.settings = ProjectSettings()
        }
    }
}
