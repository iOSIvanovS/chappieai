// AIClientProtocol.swift
// ChappieCore
//
// Common interface for all AI provider clients.
//
// WHY A PROTOCOL:
// Different providers use different wire formats — OpenAI uses /v1/chat/completions
// with a "messages" array, Anthropic uses /v1/messages with a separate "system" field.
// AIOrchestrator doesn't need to know which wire format is in use — it just calls
// streamRequestWithTools() and gets back an AIStreamResult.
//
// IMPLEMENTATIONS:
// - AIClient        → OpenAI-compatible (any provider using /v1/chat/completions)
// - AnthropicClient → Anthropic native API (/v1/messages)
//
// FACTORY:
// AIClientFactory.make(for:apiKey:model:) picks the right implementation based on
// model.providerProtocol. All call sites use the factory — never instantiate directly.

import Foundation

// MARK: - AIClientProtocol

/// Minimum surface that AIOrchestrator and other services need from any AI client.
public protocol AIClientProtocol: Sendable {

    /// Primary agentic loop method — streaming with tool calls.
    func streamRequestWithTools(
        systemPrompt: String,
        chatHistory: [AIMessage],
        tools: [AITool],
        stallTimeout: TimeInterval,
        onToken: (@Sendable (String) -> Void)?
    ) async throws -> AIStreamResult

    /// Non-streaming request — returns a single complete response.
    /// Used by WelcomeService and other lightweight one-shot requests.
    func sendRequest(
        systemPrompt: String,
        chatHistory: [AIMessage],
        tools: [AITool]
    ) async throws -> (message: AIMessage, cost: Double?, balance: Double?)

    /// Connection + model validation.
    func validateConnection() async throws

    /// Provider-level validation (no model name required).
    func validateProvider() async throws

    /// Fetches available model IDs from the provider.
    func fetchAvailableModels() async -> [String]
}
