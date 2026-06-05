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

// MARK: - ThreadSettings

/// Per-thread configuration — serialized to JSON and stored inside ThreadPayload.settingsJSON.
///
/// WHY STRUCT, NOT @Model: Settings always belong to a thread, never standalone.
public struct ThreadSettings: Codable, Sendable, Equatable, Hashable {

    /// Max messages in context window. Range: 10...1000, step 10. Default: 100.
    public var maxMessagesInContext: Int

    /// When true — all trimming is disabled, everything is sent to the model.
    ///
    /// WHY SEPARATE FLAG, NOT maxMessagesInContext = Int.max:
    /// Int.max in JSON/Codable is fragile. An explicit Bool is clear and safe.
    public var isUnlimitedContext: Bool

    /// Computed token budget: maxMessagesInContext × 500. Not stored — avoids migration on formula changes.
    public var tokenBudget: Int {
        isUnlimitedContext ? Int.max : maxMessagesInContext * 500
    }

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

    public init(
        maxMessagesInContext: Int = 100,
        isUnlimitedContext: Bool = false,
        activeProviderId: UUID? = nil,
        activeKeyId: UUID? = nil,
        activeModelName: String? = nil
    ) {
        // Clamp to valid range 10...1000 — guard against corrupted JSON values
        self.maxMessagesInContext = max(10, min(1000, maxMessagesInContext))
        self.isUnlimitedContext = isUnlimitedContext
        self.activeProviderId = activeProviderId
        self.activeKeyId = activeKeyId
        self.activeModelName = activeModelName
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
    public let projectIds: [UUID]
    /// Included so UI can show settings without an extra ThreadStore call.
    public let settings: ThreadSettings

    /// Public memberwise init — for Previews and tests.
    public init(
        id: UUID = UUID(),
        title: String,
        settings: ThreadSettings = ThreadSettings(),
        projectIds: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.settings = settings
        self.projectIds = projectIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
