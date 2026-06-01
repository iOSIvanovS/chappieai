// ProjectStore.swift
// ChappieCore
//
// Actor for CRUD operations on projects via SwiftData.
// Each project stores a security-scoped bookmark for folder access.
// Threads reference projects by UUID (in projectBindingsJSON).
//
// Why background context: ModelContext(modelContainer) instead of mainContext
// avoids Swift 6 @MainActor isolation violations.

import Foundation
import SwiftData

// MARK: - ProjectStore

/// Actor managing projects in SwiftData.
public actor ProjectStore {

    private let modelContainer: ModelContainer

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    private func makeContext() -> ModelContext {
        ModelContext(modelContainer)
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
        print("[ProjectStore] ✅ Added project '\(displayName)' (id: \(project.id))")
        return project.id
    }

    // MARK: - Read

    /// Loads all projects sorted by creation date (newest first).
    public func loadProjects() throws -> [ProjectMetadata] {
        let context = makeContext()
        let descriptor = FetchDescriptor<ProjectEntity>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor).map { ProjectMetadata(from: $0) }
    }

    /// Loads a single project by UUID. Returns nil if not found.
    public func loadProject(id: UUID) throws -> ProjectMetadata? {
        let context = makeContext()
        let descriptor = FetchDescriptor<ProjectEntity>(
            predicate: #Predicate { $0.id == id }
        )
        guard let project = try context.fetch(descriptor).first else { return nil }
        return ProjectMetadata(from: project)
    }

    /// Loads projects for a list of UUIDs, preserving the order of `ids`.
    public func loadProjects(ids: [UUID]) throws -> [ProjectMetadata] {
        guard !ids.isEmpty else { return [] }
        let context = makeContext()
        let all = try context.fetch(FetchDescriptor<ProjectEntity>())
        let map = Dictionary(uniqueKeysWithValues: all.map { ($0.id, ProjectMetadata(from: $0)) })
        return ids.compactMap { map[$0] }
    }

    /// Loads the security-scoped bookmark for a project. Used when resolving workspace URL.
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
