// ThreadModels.swift
// ChappieCore
//
// Data models for the multi-thread system.
//
// STORAGE:
// All thread data is stored via ChappieDataStore — the only place that knows about SwiftData.
// ThreadPayload (defined in ThreadStore.swift) is the persisted Codable struct.
// ThreadMetadata is the runtime Sendable DTO passed across actor boundaries.
// Messages are stored separately under Relation.threadMessages(uuid) as raw JSON Data.
//
// CODABLE COMPATIBILITY CONTRACT (never violate — stored JSON must always decode cleanly):
//   1. Never rename a stored property without adding/updating CodingKeys.
//   2. Never remove a stored property — mark optional with a default instead.
//   3. Always give new properties a default value so old records decode cleanly.

import Foundation

// MARK: - ThreadProjectEntry

/// A project attached to a specific thread. Stored inside ThreadPayload.projectsJSON.
///
/// WHY HERE, NOT IN ProjectStore:
/// Projects are thread-scoped — the same folder can be attached to different threads
/// with different settings. There is no global project registry anymore.
/// absolutePath is stored at attachment time (from the URL the user picked) and is
/// used directly for FS access — no bookmark resolution needed.
public struct ThreadProjectEntry: Codable, Sendable, Identifiable, Hashable {

    public let id: UUID
    public var displayName: String
    public var absolutePath: String
    public var settings: ProjectSettings
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        absolutePath: String,
        settings: ProjectSettings = ProjectSettings(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.absolutePath = absolutePath
        self.settings = settings
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName  = "display_name"
        case absolutePath = "absolute_path"
        case settings
        case createdAt    = "created_at"
    }
}

// MARK: - ThreadSettings

/// Per-thread configuration — serialized to JSON and stored inside ThreadPayload.settingsJSON.
///
/// WHY STRUCT, NOT @Model: Settings always belong to a thread, never standalone.
public struct ThreadSettings: Codable, Sendable, Equatable, Hashable {

    /// Max messages in context window. Range: 10...1000, step 10. Default: 30.
    public var maxMessagesInContext: Int

    /// When true — all trimming is disabled, everything is sent to the model.
    ///
    /// WHY SEPARATE FLAG, NOT maxMessagesInContext = Int.max:
    /// Int.max in JSON/Codable is fragile. An explicit Bool is clear and safe.
    public var isUnlimitedContext: Bool

    /// UUID of the AI provider for this thread. nil = use default provider.
    ///
    /// WHY UUID, NOT INLINE PROVIDER: avoids duplication — thread always reflects latest provider config.
    public var activeProviderId: UUID?

    /// UUID of the active API key for this thread. nil = use first available key from the provider.
    ///
    /// WHY UUID, NOT KEY VALUE: thread stores only the reference — actual secret loaded from Keychain.
    /// Thread isolation: each thread carries its own key reference, never shared across threads.
    public var activeKeyId: UUID?

    /// Model name for this thread. nil = no model selected.
    /// If the model is deleted from the provider, the thread shows a warning banner.
    public var activeModelName: String?

    /// Terminal access level for this thread.
    /// Thread-level setting — independent of any attached project role.
    /// Starter plan forces this to .none across all threads.
    public var terminalAccess: TerminalAccessLevel

    /// Curl-Chappie (HTTP request tool) switch for this thread. Off by default.
    public var curlEnabled: Bool

    /// Allow-list of hosts Curl-Chappie may talk to in this thread, with per-host permission.
    /// Empty = the tool has nowhere to send anything.
    public var curlHosts: [CurlHost]

    public init(
        maxMessagesInContext: Int = 30,
        isUnlimitedContext: Bool = false,
        activeProviderId: UUID? = nil,
        activeKeyId: UUID? = nil,
        activeModelName: String? = nil,
        terminalAccess: TerminalAccessLevel = .none,
        curlEnabled: Bool = false,
        curlHosts: [CurlHost] = []
    ) {
        // Clamp to valid range 10...1000 — guard against corrupted JSON values
        self.maxMessagesInContext = max(10, min(1000, maxMessagesInContext))
        self.isUnlimitedContext = isUnlimitedContext
        self.activeProviderId = activeProviderId
        self.activeKeyId = activeKeyId
        self.activeModelName = activeModelName
        self.terminalAccess = terminalAccess
        self.curlEnabled = curlEnabled
        self.curlHosts = curlHosts
    }

    // MARK: Codable (manual)
    // WHY MANUAL: synthesized decoding throws on a missing key, and callers fall back to
    // ThreadSettings() on any decode error — one new field would silently reset every
    // old thread's provider, model and terminal settings.

    private enum CodingKeys: String, CodingKey {
        case maxMessagesInContext, isUnlimitedContext, activeProviderId, activeKeyId
        case activeModelName, terminalAccess, curlEnabled, curlHosts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maxMessagesInContext: try c.decodeIfPresent(Int.self, forKey: .maxMessagesInContext) ?? 30,
            isUnlimitedContext: try c.decodeIfPresent(Bool.self, forKey: .isUnlimitedContext) ?? false,
            activeProviderId: try c.decodeIfPresent(UUID.self, forKey: .activeProviderId),
            activeKeyId: try c.decodeIfPresent(UUID.self, forKey: .activeKeyId),
            activeModelName: try c.decodeIfPresent(String.self, forKey: .activeModelName),
            terminalAccess: try c.decodeIfPresent(TerminalAccessLevel.self, forKey: .terminalAccess) ?? .none,
            curlEnabled: try c.decodeIfPresent(Bool.self, forKey: .curlEnabled) ?? false,
            curlHosts: try c.decodeIfPresent([CurlHost].self, forKey: .curlHosts) ?? []
        )
    }
}

// MARK: - ThreadMetadata

/// Sendable DTO for passing thread data from actor to UI.
///
/// WHY NOT ThreadPayload DIRECTLY:
/// ThreadPayload stores settings as raw JSON Data — not ergonomic for UI.
/// ThreadMetadata decodes settings eagerly and exposes typed values.
/// Keeping them separate makes the persistence/UI boundary explicit.
public struct ThreadMetadata: Sendable, Identifiable, Hashable {

    public let id: UUID
    public let title: String
    public let createdAt: Date
    /// Used for sorting in the sidebar.
    public let updatedAt: Date
    /// Thread-scoped projects. Source of truth for project attachment.
    public let projects: [ThreadProjectEntry]
    /// Included so UI can show settings without an extra ThreadStore call.
    public let settings: ThreadSettings

    /// Public memberwise init — for Previews and tests.
    public init(
        id: UUID = UUID(),
        title: String,
        settings: ThreadSettings = ThreadSettings(),
        projects: [ThreadProjectEntry] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.settings = settings
        self.projects = projects
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
