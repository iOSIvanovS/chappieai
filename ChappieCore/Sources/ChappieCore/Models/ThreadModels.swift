// ThreadModels.swift
// ChappieCore
//
// Data models for the multi-thread system.
//
// JSON SERIALIZATION PRINCIPLE:
// SwiftData stores only primitives and Data. Complex objects are serialized via JSONEncoder
// and stored as Data — schema stays stable, only Codable structs evolve.
//
// NO DEPENDENCY ON ChatMessage:
// ChatMessage lives in the UI target. ChappieCore stores messagesJSON: Data and lets
// ChappieViewModel handle serialization/deserialization.

import Foundation
import SwiftData

// MARK: - ThreadEntity

/// SwiftData record for a single thread.
///
/// WHY ONLY PRIMITIVES AND DATA: SwiftData has limited support for custom Codable types in @Model.
/// Storing complex structs directly causes migration issues — JSON-in-Data avoids this entirely.
///
/// WHY @Model FINAL CLASS: SwiftData requires reference types for change tracking via @Observable.
@Model
public final class ThreadEntity {

    public var id: UUID
    public var title: String
    public var createdAt: Date
    /// Used for sorting — most recently active at top.
    public var updatedAt: Date

    /// [ChatMessage] serialized via JSONEncoder. UI target owns the type.
    public var messagesJSON: Data

    /// ThreadSettings serialized via JSONEncoder.
    public var settingsJSON: Data

    /// [UUID] of projects bound to this thread, serialized via JSONEncoder.
    ///
    /// WHY UUID LIST, NOT SwiftData RELATIONSHIP:
    /// Simpler than a typed relationship and avoids cascading delete complexity.
    public var projectBindingsJSON: Data

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

// MARK: - ThreadSettings

/// Per-thread configuration — serialized to JSON and stored in ThreadEntity.settingsJSON.
///
/// WHY STRUCT, NOT @Model: Settings always belong to a thread, never standalone.
public struct ThreadSettings: Codable, Sendable, Equatable, Hashable {

    /// Max messages in context window. Range: 10...1000. Default: 20.
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

    /// Model name for this thread. nil = first model from provider.
    /// If the model is deleted from the provider, the thread shows a warning banner.
    public var activeModelName: String?

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

// MARK: - ThreadMetadata

/// Sendable DTO for passing thread data from actor to UI.
///
/// WHY NOT ThreadEntity DIRECTLY:
/// ThreadEntity is a SwiftData @Model bound to a ModelContext — not Sendable.
/// Passing it across actor boundaries violates Swift 6 concurrency rules.
/// ThreadMetadata contains only value types — fully Sendable.
public struct ThreadMetadata: Sendable, Identifiable, Hashable {

    public let id: UUID
    public let title: String
    public let createdAt: Date
    /// Used for sorting in the sidebar.
    public let updatedAt: Date
    public let projectIds: [UUID]
    /// Included so UI can show settings without an extra ThreadStore call.
    public let settings: ThreadSettings

    /// Creates ThreadMetadata from ThreadEntity (inside actor only).
    init(from entity: ThreadEntity) {
        self.id = entity.id
        self.title = entity.title
        self.createdAt = entity.createdAt
        self.updatedAt = entity.updatedAt

        if !entity.projectBindingsJSON.isEmpty,
           let ids = try? JSONDecoder().decode([UUID].self, from: entity.projectBindingsJSON) {
            self.projectIds = ids
        } else {
            self.projectIds = []
        }

        if !entity.settingsJSON.isEmpty,
           let settings = try? JSONDecoder().decode(ThreadSettings.self, from: entity.settingsJSON) {
            self.settings = settings
        } else {
            self.settings = ThreadSettings()
        }
    }

    /// Public memberwise init — for Previews and tests.
    ///
    /// WHY EXPLICIT PUBLIC INIT: Swift auto-generates memberwise init as internal.
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
