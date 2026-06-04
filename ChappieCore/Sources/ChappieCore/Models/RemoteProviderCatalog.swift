// RemoteProviderCatalog.swift
// ChappieCore
//
// Codable models for providers.json — the remote catalog hosted on GitHub.
//
// DESIGN:
// These are pure data-transfer structs. They are NOT domain models (AIProvider).
// Conversion to AIProvider happens in ProvidersRemoteService, not here.
//
// JSON SHAPE:
// {
//   "meta": { "version": "1.0", "updated_at": "...", "providers_count": 10, "models_count": 211 },
//   "providers": [
//     {
//       "id": "openai",
//       "name": "OpenAI",
//       "base_url": "https://api.openai.com",
//       "requires_api_key": true,   // optional, defaults to true
//       "models": [
//         { "id": "gpt-4o", "name": "GPT-4o", "endpoint": "/v1/chat/completions", "protocol": "openai" }
//       ]
//     }
//   ]
// }

import Foundation

// MARK: - RemoteProviderCatalog

/// Top-level structure of providers.json.
public struct RemoteProviderCatalog: Codable, Sendable {
    public let meta: RemoteCatalogMeta
    public let providers: [RemoteProvider]
}

// MARK: - RemoteCatalogMeta

/// Metadata block from providers.json.
public struct RemoteCatalogMeta: Codable, Sendable {
    public let version: String
    public let updatedAt: String
    public let providersCount: Int
    public let modelsCount: Int

    private enum CodingKeys: String, CodingKey {
        case version
        case updatedAt = "updated_at"
        case providersCount = "providers_count"
        case modelsCount = "models_count"
    }
}

// MARK: - RemoteProvider

/// A single provider entry from the catalog.
public struct RemoteProvider: Codable, Sendable, Identifiable {
    /// Stable slug, e.g. "openai", "anthropic", "groq".
    public let id: String
    /// Human-readable name, e.g. "OpenAI", "Anthropic".
    public let name: String
    /// Base URL without path, e.g. "https://api.openai.com".
    public let baseURL: String
    /// Whether an API key is required. Defaults to true. False for local providers like Ollama.
    public let requiresApiKey: Bool
    /// All models offered by this provider.
    public let models: [RemoteModel]

    private enum CodingKeys: String, CodingKey {
        case id, name, models
        case baseURL = "base_url"
        case requiresApiKey = "requires_api_key"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        // Default to true — all existing providers require a key
        requiresApiKey = try container.decodeIfPresent(Bool.self, forKey: .requiresApiKey) ?? true
        models = try container.decode([RemoteModel].self, forKey: .models)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(requiresApiKey, forKey: .requiresApiKey)
        try container.encode(models, forKey: .models)
    }

    /// Convenience: full endpoint for the first model (or a sensible default).
    public var defaultEndpoint: String {
        guard let first = models.first else {
            return baseURL + "/v1/chat/completions"
        }
        return baseURL + first.endpoint
    }

    /// All unique full endpoint URLs across models of this provider.
    public var uniqueEndpoints: [String] {
        var seen = Set<String>()
        return models.compactMap { model in
            let full = baseURL + model.endpoint
            return seen.insert(full).inserted ? full : nil
        }
    }
}

// MARK: - RemoteModel

/// A single model entry inside a RemoteProvider.
public struct RemoteModel: Codable, Sendable, Identifiable {
    /// Model ID as expected by the API, e.g. "gpt-4o", "claude-opus-4-20250514".
    public let id: String
    /// Human-readable name, e.g. "GPT-4o", "Claude Opus 4".
    public let name: String
    /// Path component of the endpoint, e.g. "/v1/chat/completions", "/v1/messages".
    public let endpoint: String
    /// Wire protocol: "openai" or "anthropic".
    public let `protocol`: String
}
