// AIProviderModels.swift
// ChappieCore
//
// Domain models for AI providers — OpenAI-compatible endpoints.
//
// ARCHITECTURE: JSON-SERIALIZATION PATTERN (swiftdata_json_pattern rule)
// We never use SwiftData @Model graph for domain models.
// AIProvider is a plain Codable struct. AIProviderEntity stores it as JSON string.
// This gives full freedom to evolve the model without SwiftData migrations.
//
// KEYCHAIN STORAGE:
// API keys are stored in Keychain, NOT in SwiftData.
// Key per provider: provider.id.uuidString
// This keeps secrets out of the database entirely.
//
// TWO-LEVEL STRUCTURE (providers refactor):
// AIProvider — one endpoint + API key + user-defined name + list of saved model names.
// Thread stores (activeProviderId, activeModelName) — picks one model from provider's list.
// Deleting provider or model is always allowed — orphaned threads show a warning banner.

import Foundation
import SwiftData

// MARK: - AIProvider (Domain Model)

/// A single AI provider configuration — one endpoint, one API key, multiple saved models.
///
/// IMMUTABLE BY DESIGN:
/// All mutations go through AIProviderStore which re-serializes to JSON.
/// This ensures consistency between in-memory and persisted state.
public struct AIProvider: Codable, Sendable, Identifiable, Equatable, Hashable {

    // MARK: - Fields

    /// Stable unique identifier. Never changes after creation.
    public let id: UUID

    /// User-defined display name for this provider, e.g. "Work OpenAI", "Personal Groq".
    /// Defaults to the host name if not set by user.
    public var name: String

    /// Full endpoint URL, e.g. "https://api.aitunnel.ru/v1/chat/completions"
    public var endpoint: String

    /// List of model names the user has saved for this provider.
    /// Can be populated from GET /v1/models or entered manually.
    /// User can add/remove individual models.
    public var models: [String]

    // MARK: - Computed

    /// Display-friendly host extracted from the endpoint URL.
    /// Example: "https://api.aitunnel.ru/v1/chat/completions" → "api.aitunnel.ru"
    public var displayHost: String {
        URL(string: endpoint)?.host ?? endpoint
    }

    /// The label shown in lists — user name if set, otherwise the host.
    public var displayName: String {
        name.isEmpty ? displayHost : name
    }

    // MARK: - Init

    public init(
        id: UUID = UUID(),
        name: String = "",
        endpoint: String,
        models: [String] = []
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.models = models
    }

    // MARK: - Hashable

    /// Hash based on id only — id is the stable identity.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - AIProviderEntity (SwiftData Storage)

/// SwiftData entity for persisting AI providers.
///
/// JSON PATTERN: stores the entire AIProvider as a JSON string.
/// No graph, no relationships, no migrations needed when AIProvider evolves.
///
/// KEYCHAIN: API key is NOT stored here. It lives in Keychain under provider.id.uuidString.
@Model
public final class AIProviderEntity {

    // MARK: - Fields

    /// Provider UUID — mirrors AIProvider.id for fast lookup without deserializing JSON.
    public var id: UUID

    /// AIProvider serialized as JSON string.
    public var json: String

    /// Whether this provider is the default (used for new threads).
    public var isDefault: Bool

    /// Creation timestamp for ordering in the list.
    public var createdAt: Date

    // MARK: - Init

    public init(provider: AIProvider, isDefault: Bool = false) {
        self.id = provider.id
        self.json = (try? String(data: JSONEncoder().encode(provider), encoding: .utf8)) ?? "{}"
        self.isDefault = isDefault
        self.createdAt = Date()
    }

    // MARK: - Deserialization

    /// Parses the stored JSON back into an AIProvider domain model.
    /// Returns nil if JSON is malformed (should never happen in practice).
    public func toProvider() -> AIProvider? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AIProvider.self, from: data)
    }

    /// Updates the stored JSON from a mutated AIProvider.
    public func update(from provider: AIProvider) {
        self.json = (try? String(data: JSONEncoder().encode(provider), encoding: .utf8)) ?? self.json
    }
}
