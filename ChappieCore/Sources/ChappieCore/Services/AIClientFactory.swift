// AIClientFactory.swift
// ChappieCore
//
// Single factory for creating AI clients — picks the right implementation
// based on model.providerProtocol.
//
// WHY A FACTORY:
// Call sites (ChappieViewModel+Providers, AddProviderSheet) should not know
// which client class to instantiate. The factory encapsulates that decision.
// If a new protocol is added (e.g. Google Gemini), only this file changes.

import Foundation

// MARK: - AIClientFactory

public enum AIClientFactory {

    /// Creates the correct AI client for the given provider + model combination.
    ///
    /// - Parameters:
    ///   - provider: The active AIProvider (carries baseURL and protocol).
    ///   - apiKey: The resolved API key secret (from Keychain).
    ///   - model: The selected AIModel (carries endpoint path and protocol override).
    /// - Returns: An `any AIClientProtocol` — either AIClient or AnthropicClient.
    public static func make(
        for provider: AIProvider,
        apiKey: String,
        model: AIModel
    ) -> any AIClientProtocol {
        // Model-level protocol takes precedence over provider-level default.
        let proto = model.providerProtocol

        switch proto {
        case .anthropic:
            return AnthropicClient(
                baseURL: provider.baseURL,
                apiKey: apiKey,
                modelName: model.id
            )

        case .openai:
            // Full endpoint = baseURL + model's endpoint path
            let endpoint = provider.baseURL + model.endpoint
            return AIClient(
                endpoint: endpoint,
                apiKey: apiKey,
                modelName: model.id
            )
        }
    }

    /// Convenience factory for validation — uses the provider's default protocol.
    ///
    /// Used in AddProviderSheet step 1 where no model is selected yet.
    /// Creates a client pointing at the validation endpoint (baseURL + /v1/models or similar).
    public static func makeForValidation(
        baseURL: String,
        apiKey: String,
        providerProtocol: ProviderProtocol = .openai
    ) -> any AIClientProtocol {
        switch providerProtocol {
        case .anthropic:
            // For Anthropic validation, use a dummy model name — validateProvider() sends max_tokens=1
            return AnthropicClient(baseURL: baseURL, apiKey: apiKey, modelName: "")
        case .openai:
            let endpoint = baseURL + "/v1/models"
            return AIClient(endpoint: endpoint, apiKey: apiKey, modelName: "")
        }
    }
}
