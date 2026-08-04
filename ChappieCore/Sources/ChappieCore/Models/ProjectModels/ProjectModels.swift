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

    /// Controls availability of build_project / run_tests for this specific project.
    /// Default true — preserves existing behavior for projects created before this setting existed.
    /// WHY GATE BOTH TOOLS: running tests without a fresh build is unsafe
    /// (see rule "FORBIDDEN: run_tests before build_project"). Disabling compile must disable testing too.
    /// Useful for large projects where compilation is too slow for the AI to wait on —
    /// user builds/tests manually and reports results back in chat instead.
    public var buildEnabled: Bool

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
        terminalAccess: TerminalAccessLevel = .none,
        buildEnabled: Bool = true
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
        self.buildEnabled = buildEnabled
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

    // MARK: - Codable (manual — new fields must decode safely from old stored JSON)

    private enum CodingKeys: String, CodingKey {
        case agentRole, isProgrammingProject, devEnvironment, gitAccess, testsAccess
        case architectureEnabled, architectureLanguage, commentsEnabled, commentsLanguage
        case terminalAccess, buildEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentRole = try c.decodeIfPresent(AgentRole.self, forKey: .agentRole) ?? .advisor
        isProgrammingProject = try c.decodeIfPresent(Bool.self, forKey: .isProgrammingProject) ?? false
        devEnvironment = try c.decodeIfPresent(DevEnvironment.self, forKey: .devEnvironment) ?? .unknown
        gitAccess = try c.decodeIfPresent(GitAccessLevel.self, forKey: .gitAccess) ?? .none
        testsAccess = try c.decodeIfPresent(TestsAccessLevel.self, forKey: .testsAccess) ?? .none
        architectureEnabled = try c.decodeIfPresent(Bool.self, forKey: .architectureEnabled) ?? false
        architectureLanguage = try c.decodeIfPresent(ProjectLanguage.self, forKey: .architectureLanguage) ?? .english
        commentsEnabled = try c.decodeIfPresent(Bool.self, forKey: .commentsEnabled) ?? false
        commentsLanguage = try c.decodeIfPresent(ProjectLanguage.self, forKey: .commentsLanguage) ?? .english
        terminalAccess = try c.decodeIfPresent(TerminalAccessLevel.self, forKey: .terminalAccess) ?? .none
        // Old records predate this field — default to true (build was always allowed before).
        buildEnabled = try c.decodeIfPresent(Bool.self, forKey: .buildEnabled) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(agentRole, forKey: .agentRole)
        try c.encode(isProgrammingProject, forKey: .isProgrammingProject)
        try c.encode(devEnvironment, forKey: .devEnvironment)
        try c.encode(gitAccess, forKey: .gitAccess)
        try c.encode(testsAccess, forKey: .testsAccess)
        try c.encode(architectureEnabled, forKey: .architectureEnabled)
        try c.encode(architectureLanguage, forKey: .architectureLanguage)
        try c.encode(commentsEnabled, forKey: .commentsEnabled)
        try c.encode(commentsLanguage, forKey: .commentsLanguage)
        try c.encode(terminalAccess, forKey: .terminalAccess)
        try c.encode(buildEnabled, forKey: .buildEnabled)
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
