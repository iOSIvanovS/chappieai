// BuiltInProviders.swift
// ChappieCore
//
// Hardcoded provider presets shown in the "Add provider" picker.
//
// WHY HARDCODED: model lists change every week and were a maintenance burden as a remote
// catalog. A preset only carries what rarely changes (URL, protocol, icon, chat path);
// models are always typed by the user or loaded from the provider's own /models endpoint.

import Foundation

// MARK: - BuiltInProvider

public struct BuiltInProvider: Sendable, Identifiable, Equatable {
    /// Stable slug. Stored in AIProvider.catalogId — never rename an existing id.
    public let id: String
    public let name: String
    /// Base URL without path.
    public let baseURL: String
    public let requiresApiKey: Bool
    public let iconName: String
    public let iconColor: String
    public let providerProtocol: ProviderProtocol
    /// Chat endpoint path. Differs per provider (e.g. Groq "/openai/v1/chat/completions"),
    /// so it is stored here and copied into every model the user adds.
    public let chatPath: String
    /// True when the provider accepts the top-level `cache_control` field (Anthropic-style prompt
    /// caching through an OpenAI-compatible API). Every other provider may reject it with HTTP 400.
    public let supportsPromptCaching: Bool
    /// Separate balance request for providers that do not put `usage.balance` into chat responses.
    public let balanceEndpoint: BalanceEndpoint?

    /// Part of chatPath before the standard "/v1/chat/completions" tail ("/openai" for Groq).
    /// Needed because the /models endpoint lives under the same prefix.
    public var pathPrefix: String {
        let tail = "/v1/chat/completions"
        return chatPath.hasSuffix(tail) ? String(chatPath.dropLast(tail.count)) : ""
    }

    public init(
        id: String,
        name: String,
        baseURL: String,
        requiresApiKey: Bool = true,
        iconName: String,
        iconColor: String,
        providerProtocol: ProviderProtocol = .openai,
        chatPath: String = "/v1/chat/completions",
        supportsPromptCaching: Bool = false,
        balanceEndpoint: BalanceEndpoint? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.requiresApiKey = requiresApiKey
        self.iconName = iconName
        self.iconColor = iconColor
        self.providerProtocol = providerProtocol
        self.chatPath = chatPath
        self.supportsPromptCaching = supportsPromptCaching
        self.balanceEndpoint = balanceEndpoint
    }
}

// MARK: - BalanceEndpoint

/// GET endpoint returning the account balance as a JSON number at `valuePath`
/// (e.g. RouterAI: GET /api/v1/credits -> {"data":{"credits":897.2}}).
public struct BalanceEndpoint: Sendable, Equatable {
    /// Absolute path on the preset's baseURL host.
    public let path: String
    /// Keys to walk from the JSON root to the number.
    public let valuePath: [String]

    public init(path: String, valuePath: [String]) {
        self.path = path
        self.valuePath = valuePath
    }

    /// Extracts the number from a response body; nil when the shape differs.
    public func parse(_ data: Data) -> Double? {
        guard var node = try? JSONSerialization.jsonObject(with: data) else { return nil }
        for key in valuePath {
            guard let dict = node as? [String: Any], let next = dict[key] else { return nil }
            node = next
        }
        return (node as? NSNumber)?.doubleValue
    }
}

// MARK: - BuiltInProviders

public enum BuiltInProviders {

    public static let all: [BuiltInProvider] = [
        BuiltInProvider(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com",
                        iconName: "brain", iconColor: "#10A37F"),
        BuiltInProvider(id: "anthropic", name: "Anthropic", baseURL: "https://api.anthropic.com",
                        iconName: "sparkles", iconColor: "#D4622A",
                        providerProtocol: .anthropic, chatPath: "/v1/messages"),
        BuiltInProvider(id: "google", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com",
                        iconName: "star.fill", iconColor: "#4285F4"),
        BuiltInProvider(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com",
                        iconName: "eye.fill", iconColor: "#4D6BFE"),
        BuiltInProvider(id: "groq", name: "Groq", baseURL: "https://api.groq.com",
                        iconName: "bolt.fill", iconColor: "#F55036",
                        chatPath: "/openai/v1/chat/completions"),
        BuiltInProvider(id: "mistral", name: "Mistral AI", baseURL: "https://api.mistral.ai",
                        iconName: "wind", iconColor: "#FF7000"),
        BuiltInProvider(id: "xai", name: "xAI (Grok)", baseURL: "https://api.x.ai",
                        iconName: "x.circle.fill", iconColor: "#000000"),
        BuiltInProvider(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai",
                        iconName: "arrow.triangle.branch", iconColor: "#6366F1",
                        chatPath: "/api/v1/chat/completions"),
        BuiltInProvider(id: "aitunnel", name: "AITunnel", baseURL: "https://api.aitunnel.ru",
                        iconName: "network", iconColor: "#0A84FF",
                        supportsPromptCaching: true),
        // Verified live 2026-11-13: top-level cache_control gives cached_tokens on the next call,
        // usage.cost is the per-request price in RUB. Models endpoint is /api/v1/models (pathPrefix /api).
        BuiltInProvider(id: "routerai", name: "RouterAI", baseURL: "https://routerai.ru",
                        iconName: "point.3.connected.trianglepath.dotted", iconColor: "#7C3AED",
                        chatPath: "/api/v1/chat/completions",
                        supportsPromptCaching: true,
                        balanceEndpoint: BalanceEndpoint(path: "/api/v1/credits", valuePath: ["data", "credits"])),
        BuiltInProvider(id: "ollama", name: "Ollama (Local)", baseURL: "http://localhost:11434",
                        requiresApiKey: false, iconName: "desktopcomputer", iconColor: "#3E8914"),
    ]

    public static func find(id: String) -> BuiltInProvider? {
        all.first { $0.id == id }
    }

    /// Preset whose host equals the host of `baseURL`. Lets providers added by hand
    /// ("manual setup", no catalogId) get the same caching/balance behaviour.
    public static func find(baseURL: String) -> BuiltInProvider? {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return nil }
        return all.first { URL(string: $0.baseURL)?.host?.lowercased() == host }
    }
}
