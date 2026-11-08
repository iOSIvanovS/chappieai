// AIProviderModels.swift
// ChappieCore
//
// Domain models for AI providers.
//
// ARCHITECTURE: JSON-SERIALIZATION PATTERN
// AIProvider is a plain Codable struct stored as [AIProvider] in SQLiteStorage.
// No schema migrations needed — domain structs evolve freely as Codable.
//
// KEYCHAIN STORAGE:
// API keys are stored in Keychain, NOT in SQLite.
// Each APIKey is stored under its own apiKey.id.uuidString — not under provider.id.
//
// BUILT-IN PRESETS:
// catalogId links a provider to a BuiltInProvider preset (e.g. "openai", "groq"). The field name is
// historical (stored JSON key "catalog_id") — never rename it. nil means "Custom" mode, no preset.
// providerProtocol tells the AI client which wire protocol to use (OpenAI vs Anthropic).
// authScheme tells the client which Authorization header format to use.
// requiresApiKey = false for local providers (Ollama) — no key needed, empty string passed.
//
// ICONS:
// iconName = SF Symbol name copied from the preset at creation (e.g. "brain", "sparkles").
// iconColor = hex string copied from the preset (e.g. "#10A37F"). nil = use accent color.
// Custom providers get "wrench.and.screwdriver" + nil (accent color).
//
// ORIGIN:
// origin = .catalog → created from a built-in preset.
// origin = .custom  → added manually.
// Old providers without origin field default to .catalog via decodeIfPresent.
//
// MULTI-KEY STRUCTURE:
// AIProvider — one baseURL + user-defined name + list of APIKey + list of saved AIModel.
// APIKey     — one named key with stable UUID. Keychain entry keyed by apiKey.id.uuidString.
// Thread stores (activeProviderId, activeKeyId, activeModelName) — picks one key+model.
// Deleting provider or model is always allowed — orphaned threads show a warning banner.
//
// CODABLE COMPATIBILITY CONTRACT (never violate — stored JSON must always decode cleanly):
//   1. Never rename a stored property without adding/updating CodingKeys.
//   2. Never remove a stored property — mark optional with a default instead.
//   3. Always give new properties a default value so old records decode cleanly.

import Foundation

// MARK: - ProviderProtocol

/// Wire protocol used to communicate with a provider.
public enum ProviderProtocol: String, Codable, Sendable, CaseIterable {
    case openai
    case anthropic
}

// MARK: - AuthScheme

/// HTTP authorization header format used by the provider.
public enum AuthScheme: String, Codable, Sendable, CaseIterable {
    case bearer
    case xApiKey = "x_api_key"
    case none
}

// MARK: - ProviderOrigin

public enum ProviderOrigin: String, Codable, Sendable {
    case catalog
    case custom
}

// MARK: - AIModel

public struct AIModel: Codable, Sendable, Identifiable, Equatable, Hashable {

    public let id: String
    public var name: String
    public var endpoint: String
    public var providerProtocol: ProviderProtocol

    public var displayName: String { name.isEmpty ? id : name }

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

    private enum CodingKeys: String, CodingKey {
        case id, name, endpoint
        case providerProtocol = "provider_protocol"
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - APIKey

public struct APIKey: Codable, Sendable, Identifiable, Equatable, Hashable {

    public let id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - AIProvider

/// A single AI provider configuration — stored directly as Codable in SQLiteStorage.
/// isDefault is stored inline — no separate entity needed.
public struct AIProvider: Codable, Sendable, Identifiable, Equatable, Hashable {

    public let id: UUID
    public var name: String
    public var baseURL: String
    public var catalogId: String?
    public var providerProtocol: ProviderProtocol
    public var authScheme: AuthScheme
    public var origin: ProviderOrigin
    public var requiresApiKey: Bool
    public var iconName: String
    public var iconColor: String?
    public var keys: [APIKey]
    public var models: [AIModel]

    /// Whether this provider is the default. Stored inline — no separate entity needed.
    /// Old records without this field default to false via decodeIfPresent.
    public var isDefault: Bool

    public var displayHost: String { URL(string: baseURL)?.host ?? baseURL }
    public var displayName: String { name.isEmpty ? displayHost : name }
    /// Built-in preset this provider was created from, if any.
    public var builtIn: BuiltInProvider? { catalogId.flatMap(BuiltInProviders.find(id:)) }

    /// Chat path for models added by hand. Presets differ (Groq, OpenRouter), custom providers use the protocol default.
    public var defaultChatPath: String {
        if let builtIn { return builtIn.chatPath }
        return providerProtocol == .anthropic ? "/v1/messages" : "/v1/chat/completions"
    }

    /// Base URL for /v1/models discovery and key validation: presets with a path prefix
    /// (Groq "/openai", OpenRouter "/api") serve /models under that prefix.
    public var discoveryBaseURL: String { baseURL + (builtIn?.pathPrefix ?? "") }

    public init(
        id: UUID = UUID(),
        name: String = "",
        baseURL: String,
        catalogId: String? = nil,
        providerProtocol: ProviderProtocol = .openai,
        authScheme: AuthScheme? = nil,
        origin: ProviderOrigin = .catalog,
        requiresApiKey: Bool = true,
        iconName: String = "cpu",
        iconColor: String? = nil,
        keys: [APIKey] = [],
        models: [AIModel] = [],
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.catalogId = catalogId
        self.providerProtocol = providerProtocol
        self.authScheme = authScheme ?? (providerProtocol == .anthropic ? .xApiKey : .bearer)
        self.origin = origin
        self.requiresApiKey = requiresApiKey
        self.iconName = iconName
        self.iconColor = iconColor
        self.keys = keys
        self.models = models
        self.isDefault = isDefault
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, keys, models, origin
        case baseURL          = "base_url"
        case catalogId        = "catalog_id"
        case providerProtocol = "provider_protocol"
        case authScheme       = "auth_scheme"
        case requiresApiKey   = "requires_api_key"
        case iconName         = "icon_name"
        case iconColor        = "icon_color"
        case isDefault        = "is_default"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id               = try c.decode(UUID.self, forKey: .id)
        name             = try c.decode(String.self, forKey: .name)
        baseURL          = try c.decode(String.self, forKey: .baseURL)
        catalogId        = try c.decodeIfPresent(String.self, forKey: .catalogId)
        providerProtocol = try c.decodeIfPresent(ProviderProtocol.self, forKey: .providerProtocol) ?? .openai
        keys             = try c.decodeIfPresent([APIKey].self, forKey: .keys) ?? []
        models           = try c.decodeIfPresent([AIModel].self, forKey: .models) ?? []
        let scheme       = try c.decodeIfPresent(AuthScheme.self, forKey: .authScheme)
        authScheme       = scheme ?? (providerProtocol == .anthropic ? .xApiKey : .bearer)
        origin           = try c.decodeIfPresent(ProviderOrigin.self, forKey: .origin) ?? .catalog
        requiresApiKey   = try c.decodeIfPresent(Bool.self, forKey: .requiresApiKey) ?? true
        iconName         = try c.decodeIfPresent(String.self, forKey: .iconName) ?? "cpu"
        iconColor        = try c.decodeIfPresent(String.self, forKey: .iconColor)
        isDefault        = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
