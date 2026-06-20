// ProjectModels.swift
// ChappieCore
//
// Domain models for projects: ProjectSettings and ProjectMetadata.
//
// STORAGE:
// All project data is stored via ChappieDataStore — the only place that knows about SwiftData.
// ProjectPayload (defined in ProjectStore.swift) is the persisted Codable struct.
// Security-scoped bookmarks are stored separately under Relation.projectBookmark(uuid).
// ChappieDataStore is the ONLY place that knows about SwiftData — see DataStore.swift.
//
// CODABLE COMPATIBILITY CONTRACT (never violate — stored JSON must always decode cleanly):
//   1. Never rename a stored property without adding/updating CodingKeys.
//   2. Never remove a stored property — mark optional with a default instead.
//   3. Always give new properties a default value so old records decode cleanly.

import Foundation

// MARK: - ProjectSettings

/// Agent rights and configuration for a project. Serialized to JSON inside ProjectPayload.settingsJSON.
/// Safe defaults: agentRole = .advisor, everything else = off/none.
public struct ProjectSettings: Codable, Sendable, Equatable, Hashable {

    public var agentRole: AgentRole

    // Unlocks git/tests/architecture/comments/terminal settings in the UI and prompt.
    public var isProgrammingProject: Bool

    // Dev environment — controls env-specific tool injection. .unknown = not set.
    public var devEnvironment: DevEnvironment

    public var gitAccess: GitAccessLevel
    public var testsAccess: TestsAccessLevel
    public var architectureEnabled: Bool
    public var architectureLanguage: ProjectLanguage
    public var commentsEnabled: Bool
    public var commentsLanguage: ProjectLanguage
    public var terminalAccess: TerminalAccessLevel

    public init(
        agentRole: AgentRole = .advisor,
        isProgrammingProject: Bool = false,
        devEnvironment: DevEnvironment = .unknown,
        gitAccess: GitAccessLevel = .none,
        testsAccess: TestsAccessLevel = .none,
        architectureEnabled: Bool = false,
        architectureLanguage: ProjectLanguage = .english,
        commentsEnabled: Bool = false,
        commentsLanguage: ProjectLanguage = .english,
        terminalAccess: TerminalAccessLevel = .none
    ) {
        self.agentRole = agentRole
        self.isProgrammingProject = isProgrammingProject
        self.devEnvironment = devEnvironment
        self.gitAccess = gitAccess
        self.testsAccess = testsAccess
        self.architectureEnabled = architectureEnabled
        self.architectureLanguage = architectureLanguage
        self.commentsEnabled = commentsEnabled
        self.commentsLanguage = commentsLanguage
        self.terminalAccess = terminalAccess
    }

    /// Resets all access flags when downgrading to advisor role.
    public mutating func downgradeToAdvisor() {
        agentRole = .advisor
        gitAccess = .none
        testsAccess = .none
        architectureEnabled = false
        commentsEnabled = false
        terminalAccess = .none
    }
}

// MARK: - ProjectMetadata

/// Sendable DTO for passing project data across the actor boundary.
///
/// absolutePath is runtime-only — resolved from the stored path at attachment time.
/// Not re-evaluated on every sync — path is stable as long as the user doesn't move the folder.
public struct ProjectMetadata: Sendable, Identifiable, Hashable {

    public let id: UUID
    public let displayName: String
    public let createdAt: Date
    public let settings: ProjectSettings

    /// Runtime-only: absolute path resolved from the stored path at attachment time.
    /// Nil until first successful resolution.
    public var absolutePath: String?

    /// Public init for Previews, tests, and direct construction.
    public init(
        id: UUID = UUID(),
        displayName: String,
        createdAt: Date = Date(),
        settings: ProjectSettings = ProjectSettings(),
        absolutePath: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.settings = settings
        self.absolutePath = absolutePath
    }
}
