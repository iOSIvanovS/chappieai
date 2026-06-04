// AIProviderModels.swift
// ChappieCore
//
// Domain models for AI providers.
//
// ARCHITECTURE: JSON-SERIALIZATION PATTERN (swiftdata_json_pattern rule)
// AIProvider is a plain Codable struct. AIProviderEntity stores it as JSON string.
// This gives full freedom to evolve the model without SwiftData migrations.
//
// KEYCHAIN STORAGE:
// API keys are stored in Keychain, NOT in SwiftData.
// Each APIKey is stored under its own apiKey.id.uuidString — not under provider.id.
//
// CATALOG INTEGRATION:
// catalogId links a user-added provider to a RemoteProvider entry (e.g. "openai", "groq").
// nil means the provider was added manually ("Custom" mode) — no catalog entry.
// providerProtocol tells the AI client which wire protocol to use (OpenAI vs Anthropic).
//
// MULTI-KEY STRUCTURE:
// AIProvider — one baseURL + user-defined name + list of APIKey + list of saved AIModel.
// APIKey     — one named key with stable UUID. Keychain entry keyed by apiKey.id.uuidString.
// Thread stores (activeProviderId, activeKeyId, activeModelName) — picks one key+model.
// Deleting provider or model is always allowed — orphaned threads show a warning banner.

import Foundation
import SwiftData

// MARK: - ProviderProtocol

/// Wire protocol used to communicate with a provider.
public enum ProviderProtocol: String, Codable, Sendable, CaseIterable {
    /// OpenAI-compatible REST API (/v1/chat/completions, /v1/models, etc.)
    case openai
    /// Anthropic native API (/v1/messages)
    case anthropic
}

// MARK: - AIModel

/// A saved model belonging to a provider.
///
/// Richer than a plain String — carries the endpoint path and protocol
/// so the AI client knows how to call it without guessing.
public struct AIModel: Codable, Sendable, Identifiable, Equatable, Hashable {

    // MARK: - Fields

    /// Model ID as expected by the API, e.g. "gpt-4o", "claude-opus-4-20250514".
    public let id: String

    /// Human-readable display name, e.g. "GPT-4o".
    /// Falls back to id if not set.
    public var name: String

    /// Path component of the endpoint, e.g. "/v1/chat/completions", "/v1/messages".
    public var endpoint: String

    /// Wire protocol for this model.
    public var providerProtocol: ProviderProtocol

    // MARK: - Computed

    public var displayName: String { name.isEmpty ? id : name }

    // MARK: - Init

    public init(
        id: String,
        name: String = "",
        endpoint: String = "/v1/chat/completions",
        providerProtocol: ProviderProtocol = .openai
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.providerProtocol = providerProtocol
    }

    // MARK: - Codable (CodingKeys guard against future renames)

    private enum CodingKeys: String, CodingKey {
        case id, name, endpoint
        case providerProtocol = "provider_protocol"
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - APIKey

/// A single named API key belonging to a provider.
///
/// IMMUTABLE BY DESIGN: mutations go through AIProviderStore which re-serializes AIProvider JSON.
/// The actual secret is stored in Keychain under apiKey.id.uuidString — NOT in this struct.
public struct APIKey: Codable, Sendable, Identifiable, Equatable, Hashable {

    // MARK: - Fields

    /// Stable unique identifier. Never changes after creation.
    public let id: UUID

    /// User-defined label, e.g. "Work key", "Personal", "Client project".
    public var name: String

    // MARK: - Init

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - AIProvider

/// A single AI provider configuration — one base URL, multiple keys, multiple saved models.
///
/// IMMUTABLE BY DESIGN:
/// All mutations go through AIProviderStore which re-serializes to JSON.
public struct AIProvider: Codable, Sendable, Identifiable, Equatable, Hashable {

    // MARK: - Fields

    /// Stable unique identifier. Never changes after creation.
    public let id: UUID

    /// User-defined display name, e.g. "Work OpenAI", "Personal Groq".
    public var name: String

    /// Base URL without path, e.g. "https://api.openai.com".
    /// For custom providers entered manually this is the full endpoint URL (legacy compat).
    public var baseURL: String

    /// Links this provider to a RemoteProvider entry, e.g. "openai", "groq".
    /// nil → manually added custom provider (no catalog entry).
    public var catalogId: String?

    /// Default wire protocol for this provider.
    /// Individual models can override this via AIModel.providerProtocol.
    public var providerProtocol: ProviderProtocol

    /// Named API keys for this provider.
    public var keys: [APIKey]

    /// Models the user has saved for this provider.
    public var models: [AIModel]

    // MARK: - Computed

    /// Display-friendly host extracted from baseURL.
    public var displayHost: String {
        URL(string: baseURL)?.host ?? baseURL
    }

    /// The label shown in lists — user name if set, otherwise the host.
    public var displayName: String {
        name.isEmpty ? displayHost : name
    }

    /// True if this provider was added from the catalog (not custom).
    public var isFromCatalog: Bool { catalogId != nil }

    // MARK: - Init

    public init(
        id: UUID = UUID(),
        name: String = "",
        baseURL: String,
        catalogId: String? = nil,
        providerProtocol: ProviderProtocol = .openai,
        keys: [APIKey] = [],
        models: [AIModel] = []
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.catalogId = catalogId
        self.providerProtocol = providerProtocol
        self.keys = keys
        self.models = models
    }

    // MARK: - Codable (CodingKeys guard against future renames)

    private enum CodingKeys: String, CodingKey {
        case id, name, keys, models
        case baseURL = "base_url"
        case catalogId = "catalog_id"
        case providerProtocol = "provider_protocol"
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - AIProviderEntity (SwiftData Storage)

/// SwiftData entity for persisting AI providers.
///
/// JSON PATTERN: stores the entire AIProvider as a JSON string.
/// No graph, no relationships, no migrations needed when AIProvider evolves.
@Model
public final class AIProviderEntity {

    // MARK: - Fields

    public var id: UUID
    public var json: String
    public var isDefault: Bool
    public var createdAt: Date

    // MARK: - Init

    public init(provider: AIProvider, isDefault: Bool = false) {
        self.id = provider.id
        self.json = (try? String(data: JSONEncoder().encode(provider), encoding: .utf8)) ?? "{}"
        self.isDefault = isDefault
        self.createdAt = Date()
    }

    // MARK: - Deserialization

    public func toProvider() -> AIProvider? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AIProvider.self, from: data)
    }

    public func update(from provider: AIProvider) {
        self.json = (try? String(data: JSONEncoder().encode(provider), encoding: .utf8)) ?? self.json
    }
}
