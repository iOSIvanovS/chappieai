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

    public var gitAccess: GitAccessLevel

    /// May the agent create and change tests. Only a prompt line states it: writing tests goes
    /// through the shared file tools, so no tool status can express this permission.
    public var testsWriteEnabled: Bool
    public var architectureEnabled: Bool
    public var architectureLanguage: ProjectLanguage
    public var commentsEnabled: Bool
    public var commentsLanguage: ProjectLanguage

    /// Curl-Chappie secrets of this project: metadata only, values are in the Keychain
    /// (CurlSecretKeychain). Empty by default.
    public var curlSecrets: [CurlSecret]

    public init(
        agentRole: AgentRole = .advisor,
        isProgrammingProject: Bool = false,
        gitAccess: GitAccessLevel = .none,
        testsWriteEnabled: Bool = false,
        architectureEnabled: Bool = false,
        architectureLanguage: ProjectLanguage = .english,
        commentsEnabled: Bool = false,
        commentsLanguage: ProjectLanguage = .english,
        curlSecrets: [CurlSecret] = []
    ) {
        self.agentRole = agentRole
        self.isProgrammingProject = isProgrammingProject
        self.gitAccess = gitAccess
        self.testsWriteEnabled = testsWriteEnabled
        self.architectureEnabled = architectureEnabled
        self.architectureLanguage = architectureLanguage
        self.commentsEnabled = commentsEnabled
        self.commentsLanguage = commentsLanguage
        self.curlSecrets = curlSecrets
    }

    /// Resets all access flags when downgrading to advisor role.
    public mutating func downgradeToAdvisor() {
        agentRole = .advisor
        gitAccess = .none
        testsWriteEnabled = false
        architectureEnabled = false
        commentsEnabled = false
        // Curl-Chappie is not available to advisors at all. Secret metadata is kept so that
        // switching back to executor does not lose the user's setup.
    }

    // MARK: - Codable (manual — new fields must decode safely from old stored JSON)

    private enum CodingKeys: String, CodingKey {
        case agentRole, isProgrammingProject, gitAccess, testsWriteEnabled
        case architectureEnabled, architectureLanguage, commentsEnabled, commentsLanguage
        case curlSecrets
        // Legacy key, read as a plain String so that any stored value decodes.
        case legacyTestsAccess = "testsAccess"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentRole = try c.decodeIfPresent(AgentRole.self, forKey: .agentRole) ?? .advisor
        isProgrammingProject = try c.decodeIfPresent(Bool.self, forKey: .isProgrammingProject) ?? false
        gitAccess = try c.decodeIfPresent(GitAccessLevel.self, forKey: .gitAccess) ?? .none
        // The new key wins; otherwise only the old "write" level carries over, everything else is off.
        if let enabled = (try? c.decodeIfPresent(Bool.self, forKey: .testsWriteEnabled)) ?? nil {
            testsWriteEnabled = enabled
        } else {
            let legacy = (try? c.decodeIfPresent(String.self, forKey: .legacyTestsAccess)) ?? nil
            testsWriteEnabled = legacy == "write"
        }
        architectureEnabled = try c.decodeIfPresent(Bool.self, forKey: .architectureEnabled) ?? false
        architectureLanguage = try c.decodeIfPresent(ProjectLanguage.self, forKey: .architectureLanguage) ?? .english
        commentsEnabled = try c.decodeIfPresent(Bool.self, forKey: .commentsEnabled) ?? false
        commentsLanguage = try c.decodeIfPresent(ProjectLanguage.self, forKey: .commentsLanguage) ?? .english
        // Legacy "terminalAccess", "buildEnabled" and "devEnvironment" keys in old records are simply ignored
        // (unknown keys never fail decoding).
        curlSecrets = try c.decodeIfPresent([CurlSecret].self, forKey: .curlSecrets) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(agentRole, forKey: .agentRole)
        try c.encode(isProgrammingProject, forKey: .isProgrammingProject)
        try c.encode(gitAccess, forKey: .gitAccess)
        try c.encode(testsWriteEnabled, forKey: .testsWriteEnabled)
        try c.encode(architectureEnabled, forKey: .architectureEnabled)
        try c.encode(architectureLanguage, forKey: .architectureLanguage)
        try c.encode(commentsEnabled, forKey: .commentsEnabled)
        try c.encode(commentsLanguage, forKey: .commentsLanguage)
        try c.encode(curlSecrets, forKey: .curlSecrets)
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
