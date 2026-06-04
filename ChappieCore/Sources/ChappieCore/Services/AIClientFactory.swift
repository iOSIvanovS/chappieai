// AIClientFactory.swift
// ChappieCore
//
// Single factory for creating AI clients — picks the right implementation
// based on model.providerProtocol and provider.authScheme.
//
// WHY A FACTORY:
// Call sites should not know which client class to instantiate.
// The factory encapsulates that decision. Adding a new protocol (e.g. Google Gemini)
// means only this file changes.
//
// AUTH SCHEME:
// authScheme is decoupled from providerProtocol — a proxy provider can use
// Anthropic wire format (/v1/messages) with Bearer auth instead of x-api-key.
// Both clients (AIClient and AnthropicClient) accept authScheme at init.
//
// URL DESIGN:
// make() uses AIClient.init(endpoint:) — full chat URL known from model.endpoint.
// makeForValidation() uses AIClient.init(baseURL:) — no chat model yet, only base URL known.
// This avoids the double-path bug where /v1/models gets appended twice.
//
// CACHE CONTROL:
// cache_control is an AITunnel-specific extension — only sent when catalogId == "aitunnel".
// All other providers (Groq, Ollama, OpenAI, etc.) reject this field with HTTP 400.

import Foundation

// MARK: - AIClientFactory

public enum AIClientFactory {

    /// Creates the correct AI client for the given provider + model combination.
    public static func make(
        for provider: AIProvider,
        apiKey: String,
        model: AIModel
    ) -> any AIClientProtocol {
        // Model-level protocol takes precedence over provider-level default.
        let proto = model.providerProtocol
        let auth = provider.authScheme
        // cache_control is AITunnel-specific — only aitunnel catalog provider supports it.
        let supportsCaching = provider.catalogId == "aitunnel"

        switch proto {
        case .anthropic:
            return AnthropicClient(
                baseURL: provider.baseURL,
                apiKey: apiKey,
                modelName: model.id,
                authScheme: auth
            )

        case .openai:
            let endpoint = provider.baseURL + model.endpoint
            return AIClient(
                endpoint: endpoint,
                apiKey: apiKey,
                modelName: model.id,
                authScheme: auth,
                supportsCaching: supportsCaching
            )
        }
    }

    /// Convenience factory for provider-level validation and model discovery (no model selected yet).
    ///
    /// Uses AIClient.init(baseURL:) so that fetchAvailableModels appends /v1/models
    /// to the exact baseURL without double-path issues (e.g. OpenRouter: /api/v1/models).
    public static func makeForValidation(
        baseURL: String,
        apiKey: String,
        providerProtocol: ProviderProtocol = .openai,
        authScheme: AuthScheme? = nil
    ) -> any AIClientProtocol {
        // Default auth scheme by protocol if not explicitly provided.
        let resolvedAuth = authScheme ?? (providerProtocol == .anthropic ? .xApiKey : .bearer)

        switch providerProtocol {
        case .anthropic:
            return AnthropicClient(
                baseURL: baseURL,
                apiKey: apiKey,
                modelName: "",
                authScheme: resolvedAuth
            )
        case .openai:
            // Validation requests never need caching — no catalogId context available here.
            return AIClient(
                baseURL: baseURL,
                apiKey: apiKey,
                modelName: "",
                authScheme: resolvedAuth,
                supportsCaching: false
            )
        }
    }
}
