// ProjectStore.swift
// ChappieCore
//
// Actor for CRUD operations on projects via SwiftData.
// Each project stores a security-scoped bookmark for folder access.
// Threads reference projects by UUID (in projectBindingsJSON).
//
// Why background context: ModelContext(modelContainer) instead of mainContext
// avoids Swift 6 @MainActor isolation violations.
//
// CACHING:
// cachedProjects holds all projects in RAM after first load.
// loadProjects() / loadProject(id:) / loadProjects(ids:) are served from cache.
// loadBookmark() always hits SwiftData — bookmarks are large binary blobs,
// not worth caching, and accessed rarely (only during FS sync).
// All writes call refreshCache() to keep the cache consistent.

import Foundation
import SwiftData

// MARK: - ProjectStore

/// Actor managing projects in SwiftData.
public actor ProjectStore {

    private let modelContainer: ModelContainer

    // In-memory cache — populated on first read, invalidated on every write.
    private var cachedProjects: [ProjectMetadata]? = nil

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    private func makeContext() -> ModelContext {
        ModelContext(modelContainer)
    }

    // MARK: - Cache Management

    /// Reloads all projects from SwiftData into cachedProjects.
    private func refreshCache() throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ProjectEntity>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        cachedProjects = try context.fetch(descriptor).map { ProjectMetadata(from: $0) }
    }

    /// Returns cached projects, loading from SwiftData on first call.
    private func getProjects() throws -> [ProjectMetadata] {
        if let cached = cachedProjects { return cached }
        try refreshCache()
        return cachedProjects ?? []
    }

    // MARK: - Create

    /// Adds a new project. Returns the new project's UUID.
    ///
    /// Why return UUID: ProjectEntity is not Sendable, so we pass only primitives across the actor boundary.
    public func addProject(
        displayName: String,
        bookmarkData: Data,
        settings: ProjectSettings = ProjectSettings()
    ) throws -> UUID {
        let context = makeContext()
        let project = ProjectEntity(
            displayName: displayName,
            bookmarkData: bookmarkData,
            settings: settings
        )
        context.insert(project)
        try context.save()

        try refreshCache()

        print("[ProjectStore] ✅ Added project '\(displayName)' (id: \(project.id))")
        return project.id
    }

    // MARK: - Read

    /// Loads all projects sorted by creation date (newest first).
    /// Served from in-memory cache — no SwiftData hit on warm calls.
    public func loadProjects() throws -> [ProjectMetadata] {
        return try getProjects()
    }

    /// Loads a single project by UUID. Returns nil if not found.
    /// Served from in-memory cache.
    public func loadProject(id: UUID) throws -> ProjectMetadata? {
        return try getProjects().first(where: { $0.id == id })
    }

    /// Loads projects for a list of UUIDs, preserving the order of `ids`.
    /// Served from in-memory cache.
    public func loadProjects(ids: [UUID]) throws -> [ProjectMetadata] {
        guard !ids.isEmpty else { return [] }
        let map = Dictionary(uniqueKeysWithValues: try getProjects().map { ($0.id, $0) })
        return ids.compactMap { map[$0] }
    }

    /// Loads the security-scoped bookmark for a project. Used when resolving workspace URL.
    /// Always hits SwiftData — bookmarks are large binary blobs, not worth caching.
    public func loadBookmark(forProjectId id: UUID) throws -> Data? {
        let context = makeContext()
        let descriptor = FetchDescriptor<ProjectEntity>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first?.bookmarkData
    }

    // MARK: - Update

    public func updateSettings(_ settings: ProjectSettings, forProjectId projectId: UUID) throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ProjectEntity>(
            predicate: #Predicate { $0.id == projectId }
        )
        guard let project = try context.fetch(descriptor).first else { return }
        project.settingsJSON = (try? JSONEncoder().encode(settings)) ?? project.settingsJSON
        try context.save()

        try refreshCache()

        print("[ProjectStore] ✅ Updated settings for '\(project.displayName)'")
    }

    public func updateBookmark(_ bookmarkData: Data, forProjectId projectId: UUID) throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ProjectEntity>(
            predicate: #Predicate { $0.id == projectId }
        )
        guard let project = try context.fetch(descriptor).first else { return }
        project.bookmarkData = bookmarkData
        try context.save()

        // No cache refresh needed — bookmark is not stored in ProjectMetadata
        print("[ProjectStore] ✅ Updated bookmark for '\(project.displayName)'")
    }

    public func renameProject(id projectId: UUID, name: String) throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ProjectEntity>(
            predicate: #Predicate { $0.id == projectId }
        )
        guard let project = try context.fetch(descriptor).first else { return }
        project.displayName = name
        try context.save()

        try refreshCache()
    }

    // MARK: - Delete

    /// Deletes a project. Threads that reference it will get an unresolvable UUID —
    /// UI should handle this gracefully (e.g. show "Project deleted").
    public func deleteProject(id projectId: UUID) throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ProjectEntity>(
            predicate: #Predicate { $0.id == projectId }
        )
        guard let project = try context.fetch(descriptor).first else { return }
        let name = project.displayName
        context.delete(project)
        try context.save()

        try refreshCache()

        print("[ProjectStore] 🗑 Deleted project '\(name)'")
    }
}

// MARK: - ProjectMetadata

/// Sendable DTO for passing project data across the actor boundary.
///
/// Why explicit public init: Swift generates memberwise init as internal,
/// which is inaccessible from the UI target (separate module).
public struct ProjectMetadata: Sendable, Identifiable, Hashable {

    public let id: UUID
    public let displayName: String
    public let createdAt: Date
    public let settings: ProjectSettings

    /// Internal init from entity — stays inside the actor.
    init(from entity: ProjectEntity) {
        self.id = entity.id
        self.displayName = entity.displayName
        self.createdAt = entity.createdAt
        self.settings = entity.settings
    }

    /// Public init for Previews, tests, and direct construction.
    public init(
        id: UUID = UUID(),
        displayName: String,
        createdAt: Date = Date(),
        settings: ProjectSettings = ProjectSettings()
    ) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.settings = settings
    }
}
