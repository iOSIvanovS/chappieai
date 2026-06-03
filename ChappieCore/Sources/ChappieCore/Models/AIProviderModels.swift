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
// Each APIKey is stored under its own apiKey.id.uuidString — not under provider.id.
// This allows multiple keys per provider with independent lifecycle.
//
// MIGRATION FROM SINGLE-KEY SCHEMA:
// Old schema stored one key per provider under provider.id.uuidString in Keychain.
// AIProviderStore.loadProviders() detects providers with empty keys[] and migrates
// the old key into a new APIKey entry automatically (see AIProviderStore migration note).
//
// MULTI-KEY STRUCTURE:
// AIProvider — one endpoint + user-defined name + list of APIKey + list of saved model names.
// APIKey     — one named key with stable UUID. Keychain entry keyed by apiKey.id.uuidString.
// Thread stores (activeProviderId, activeKeyId, activeModelName) — picks one key+model.
// Deleting provider or model is always allowed — orphaned threads show a warning banner.

import Foundation
import SwiftData

// MARK: - APIKey (Domain Model)

/// A single named API key belonging to a provider.
///
/// IMMUTABLE BY DESIGN: mutations go through AIProviderStore which re-serializes AIProvider JSON.
/// The actual secret is stored in Keychain under apiKey.id.uuidString — NOT in this struct.
public struct APIKey: Codable, Sendable, Identifiable, Equatable, Hashable {

    // MARK: - Fields

    /// Stable unique identifier. Never changes after creation.
    public let id: UUID

    /// User-defined label, e.g. "Work key", "Personal", "Client project".
    /// Required — user must name every key for clarity.
    public var name: String

    // MARK: - Init

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - AIProvider (Domain Model)

/// A single AI provider configuration — one endpoint, multiple named API keys, multiple saved models.
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

    /// Named API keys for this provider. At least one required to use the provider.
    /// Stored as metadata only — actual secret lives in Keychain under apiKey.id.uuidString.
    public var keys: [APIKey]

    /// List of model names the user has saved for this provider.
    /// Can be populated from GET /v1/models or entered manually.
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
        keys: [APIKey] = [],
        models: [String] = []
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.keys = keys
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
/// KEYCHAIN: API key secrets are NOT stored here. They live in Keychain under apiKey.id.uuidString.
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
