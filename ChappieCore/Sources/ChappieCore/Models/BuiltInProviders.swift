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
        chatPath: String = "/v1/chat/completions"
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.requiresApiKey = requiresApiKey
        self.iconName = iconName
        self.iconColor = iconColor
        self.providerProtocol = providerProtocol
        self.chatPath = chatPath
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
                        iconName: "network", iconColor: "#0A84FF"),
        BuiltInProvider(id: "ollama", name: "Ollama (Local)", baseURL: "http://localhost:11434",
                        requiresApiKey: false, iconName: "desktopcomputer", iconColor: "#3E8914"),
    ]

    public static func find(id: String) -> BuiltInProvider? {
        all.first { $0.id == id }
    }
}
