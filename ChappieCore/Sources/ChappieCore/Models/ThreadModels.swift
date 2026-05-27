// ThreadModels.swift
// ChappieCore
//
// Data models for the multi-thread system (REFACTOR-THREADS IT-01).
// IT-10: ThreadSettings includes activeProviderId + activeModelName for per-thread selection.
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
    /// RANGE: 10...100
    /// DEFAULT: 20 (10,000 tokens — a reasonable balance)
    ///
    /// TOKEN BUDGET FORMULA:
    /// tokenBudget = maxMessagesInContext × 500
    /// Examples: 10 → 5,000 | 20 → 10,000 | 50 → 25,000 | 100 → 50,000
    public var maxMessagesInContext: Int

    /// Computed token budget based on message count.
    /// NOT stored in JSON — computed each time.
    /// Intentional: changing the formula requires no data migration.
    public var tokenBudget: Int {
        maxMessagesInContext * 500
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
        activeProviderId: UUID? = nil,
        activeModelName: String? = nil
    ) {
        self.maxMessagesInContext = max(10, min(100, maxMessagesInContext))
        self.activeProviderId = activeProviderId
        self.activeModelName = activeModelName
    }
}
