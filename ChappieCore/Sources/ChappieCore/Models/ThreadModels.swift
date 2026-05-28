// ThreadModels.swift
// ChappieCore
//
// Data models for the multi-thread system (REFACTOR-THREADS IT-01).
// IT-10: ThreadSettings includes activeProviderId + activeModelName for per-thread selection.
// IT-11: ThreadMetadata now includes settings field for direct access in UI without extra store call.
//
// JSON SERIALIZATION PRINCIPLE:
// SwiftData stores only primitives and Data. Complex objects (message arrays,
// thread settings) are serialized via JSONEncoder and stored as Data.
// On read — JSONDecoder. This fully eliminates SwiftData migration pain:
// when the model evolves, only the Codable structs change; the SwiftData schema stays the same.
//
// NO DEPENDENCY ON ChatMessage:
// ChatMessage is defined in Chappie (UI target). ChappieCore must not depend on the UI layer.
// Therefore:
// - ThreadEntity stores messagesJSON: Data (raw bytes)
// - ThreadStore works with Data directly via Generic methods (like ChatHistoryManager)
// - ChatMessage serialization/deserialization is done by ChappieViewModel (UI layer)

import Foundation
import SwiftData

// MARK: - ThreadEntity (SwiftData Storage)

/// A single thread record in the SwiftData database.
///
/// WHY ONLY PRIMITIVES AND DATA:
/// SwiftData has limited support for custom Codable types in @Model.
/// Storing complex Swift structs directly causes migration issues.
/// We serialize everything to Data via JSONEncoder — full freedom to evolve without migrations.
///
/// WHY @Model FINAL CLASS, NOT STRUCT:
/// SwiftData requires reference types for @Model — only classes support
/// change tracking via @Observable that SwiftData uses under the hood.
@Model
public final class ThreadEntity {

    // MARK: - Identity

    /// Unique thread identifier. Generated on creation, never changes.
    public var id: UUID

    /// Display title of the thread.
    /// Auto-generated from the first message words, can be renamed by user.
    public var title: String

    // MARK: - Timestamps

    /// Thread creation time.
    public var createdAt: Date

    /// Last update time. Used for sorting (most recently active at top).
    public var updatedAt: Date

    // MARK: - JSON-serialized data

    /// Thread message history serialized via JSONEncoder.
    /// Type: [ChatMessage] from the UI target — ChappieCore doesn't know about it.
    /// Same architecture as ChatHistoryManager<T: Codable>.
    public var messagesJSON: Data

    /// Thread settings serialized via JSONEncoder. Type: ThreadSettings.
    public var settingsJSON: Data

    /// List of project UUIDs bound to this thread, serialized via JSONEncoder. Type: [UUID].
    ///
    /// WHY UUID LIST, NOT SwiftData RELATIONSHIP:
    /// SwiftData relationships require strict typing and cause cascading delete complexity.
    /// A UUID list is simpler and sufficient for our use case.
    public var projectBindingsJSON: Data

    // MARK: - Init

    /// Creates a new thread with empty history and default settings.
    public init(
        id: UUID = UUID(),
        title: String,
        settings: ThreadSettings = ThreadSettings(),
        projectIds: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.messagesJSON = "[]".data(using: .utf8) ?? Data()
        self.settingsJSON = (try? JSONEncoder().encode(settings)) ?? Data()
        self.projectBindingsJSON = (try? JSONEncoder().encode(projectIds)) ?? Data()
    }
}

// MARK: - ThreadSettings (Codable thread configuration)

/// Settings for a single thread — serialized to JSON and stored in ThreadEntity.settingsJSON.
///
/// IT-10: Added activeProviderId + activeModelName for per-thread model selection.
/// Both nil = use the default provider and its first model.
///
/// WHY STRUCT, NOT @Model:
/// ThreadSettings is configuration, not a standalone entity.
/// It always belongs to a specific thread and is never needed independently.
/// Struct + Codable — the simplest and most reliable way to store nested settings.
public struct ThreadSettings: Codable, Sendable, Equatable, Hashable {

    // MARK: - Context Window

    /// Maximum number of messages in the context window.
    ///
    /// RANGE: 10...1000
    /// DEFAULT: 20 (10,000 tokens — a reasonable balance)
    ///
    /// TOKEN BUDGET FORMULA:
    /// tokenBudget = maxMessagesInContext × 500
    /// Examples: 10 → 5,000 | 20 → 10,000 | 100 → 50,000 | 1000 → 500,000
    public var maxMessagesInContext: Int

    /// When true — no context trimming is applied. All messages are sent as-is.
    ///
    /// WHY A SEPARATE FLAG, NOT maxMessagesInContext = Int.max:
    /// Int.max in JSON/Codable is fragile. An explicit Bool is clear and safe.
    /// AppConfig.init(settings:) checks this flag and sets maxMessages/tokenBudget to Int.max.
    public var isUnlimitedContext: Bool

    /// Computed token budget based on message count.
    /// NOT stored in JSON — computed each time.
    /// Intentional: changing the formula requires no data migration.
    public var tokenBudget: Int {
        isUnlimitedContext ? Int.max : maxMessagesInContext * 500
    }

    // MARK: - IT-10: Active AI Provider + Model

    /// UUID of the AI provider selected for this thread.
    ///
    /// nil = use the default provider from AIProviderStore.
    /// Set explicitly when user switches providers via the model picker row.
    ///
    /// WHY UUID, NOT INLINE PROVIDER:
    /// Provider config lives in AIProviderStore. Storing UUID here avoids duplication
    /// and ensures the thread always reflects the latest provider config.
    public var activeProviderId: UUID?

    /// Name of the specific model selected for this thread within the active provider.
    ///
    /// nil = use the first model from the provider's saved model list.
    /// Stored as a plain string — if the model is deleted from the provider,
    /// the thread becomes orphaned and shows a warning banner.
    public var activeModelName: String?

    // MARK: - Init

    public init(
        maxMessagesInContext: Int = 20,
        isUnlimitedContext: Bool = false,
        activeProviderId: UUID? = nil,
        activeModelName: String? = nil
    ) {
        // Clamp to valid range — guard against corrupted JSON values
        self.maxMessagesInContext = max(10, min(1000, maxMessagesInContext))
        self.isUnlimitedContext = isUnlimitedContext
        self.activeProviderId = activeProviderId
        self.activeModelName = activeModelName
    }
}

// MARK: - ThreadMetadata (Sendable DTO for passing outside actor)

/// Thread metadata — a safe Sendable value type for passing from actor to UI.
///
/// WHY NOT PASS ThreadEntity DIRECTLY:
/// ThreadEntity is a SwiftData @Model object. It is bound to a ModelContext and
/// is not Sendable. Passing it from actor to @MainActor UI violates Swift 6
/// Concurrency rules and can cause data races.
///
/// ThreadMetadata contains only primitives and value types — fully Sendable.
/// For mutations, UI passes threadId back to ThreadStore.
///
/// IT-11: settings field added — allows ThreadSettingsSheet to receive current settings
/// directly from ThreadMetadata without an additional ThreadStore call.
public struct ThreadMetadata: Sendable, Identifiable, Hashable {

    /// Thread UUID — used for all subsequent operations via ThreadStore
    public let id: UUID

    /// Display title of the thread
    public let title: String

    /// Creation time
    public let createdAt: Date

    /// Last update time — used for sorting in the sidebar
    public let updatedAt: Date

    /// List of project UUIDs bound to this thread
    public let projectIds: [UUID]

    /// Current thread settings — included so UI can show them without an extra store call.
    /// Kept in sync: ThreadStore.loadThreads() always deserializes settingsJSON into this field.
    public let settings: ThreadSettings

    // MARK: - Initializers

    /// Creates ThreadMetadata from ThreadEntity (inside actor only).
    ///
    /// Used by ThreadStore when loading threads from SwiftData.
    init(from entity: ThreadEntity) {
        self.id = entity.id
        self.title = entity.title
        self.createdAt = entity.createdAt
        self.updatedAt = entity.updatedAt

        // Deserialize project bindings
        if !entity.projectBindingsJSON.isEmpty,
           let ids = try? JSONDecoder().decode([UUID].self, from: entity.projectBindingsJSON) {
            self.projectIds = ids
        } else {
            self.projectIds = []
        }

        // Deserialize thread settings — fall back to defaults if data is missing or corrupt
        if !entity.settingsJSON.isEmpty,
           let settings = try? JSONDecoder().decode(ThreadSettings.self, from: entity.settingsJSON) {
            self.settings = settings
        } else {
            self.settings = ThreadSettings()
        }
    }

    /// Public memberwise initializer — for Preview and tests.
    ///
    /// WHY EXPLICIT PUBLIC INIT:
    /// Swift auto-generates memberwise init as internal for struct.
    /// Explicit public init is needed for use in the UI target (Chappie) and tests.
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
