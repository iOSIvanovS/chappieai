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
@Model
public final class ThreadEntity {

    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date

    /// [ChatMessage] serialized via JSONEncoder. UI target owns the type.
    public var messagesJSON: Data

    /// ThreadSettings serialized via JSONEncoder.
    public var settingsJSON: Data

    /// [UUID] of projects bound to this thread, serialized via JSONEncoder.
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
public struct ThreadSettings: Codable, Sendable, Equatable, Hashable {

    /// Max messages in context window. Range: 10...1000. Default: 20.
    public var maxMessagesInContext: Int

    /// When true — all trimming is disabled, everything is sent to the model.
    public var isUnlimitedContext: Bool

    /// Computed token budget: maxMessagesInContext × 500. Not stored.
    public var tokenBudget: Int {
        isUnlimitedContext ? Int.max : maxMessagesInContext * 500
    }

    /// UUID of the AI provider for this thread. nil = use default provider.
    public var activeProviderId: UUID?

    /// UUID of the active API key for this thread.
    public var activeKeyId: UUID?

    /// Model name for this thread. nil = no model selected.
    public var activeModelName: String?

    public init(
        maxMessagesInContext: Int = 20,
        isUnlimitedContext: Bool = false,
        activeProviderId: UUID? = nil,
        activeKeyId: UUID? = nil,
        activeModelName: String? = nil
    ) {
        self.maxMessagesInContext = max(10, min(1000, maxMessagesInContext))
        self.isUnlimitedContext = isUnlimitedContext
        self.activeProviderId = activeProviderId
        self.activeKeyId = activeKeyId
        self.activeModelName = activeModelName
    }
}

// MARK: - ThreadMetadata

/// Sendable DTO for passing thread data from actor to UI.
public struct ThreadMetadata: Sendable, Identifiable, Hashable {

    public let id: UUID
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date
    public let projectIds: [UUID]
    public let settings: ThreadSettings

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
