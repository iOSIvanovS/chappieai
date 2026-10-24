// AnthropicClient.swift
// ChappieCore
//
// Native Anthropic API client — implements AIClientProtocol.
//
// WIRE FORMAT vs OpenAI:
// - Endpoint: POST /v1/messages
// - System prompt: top-level "system" field (not a message)
// - Tool results: role "user" with content array of type "tool_result"
// - Tool calls: content array blocks of type "tool_use"
// - Streaming: event: content_block_delta / event: message_delta
// - Auth: x-api-key + anthropic-version header (or Bearer for proxies)
// - max_tokens is REQUIRED
// - No /v1/models endpoint — fetchAvailableModels() returns []

import Foundation

public struct AnthropicClient: Sendable, AIClientProtocol {

    // MARK: - Configuration

    let endpointURL: URL
    let apiKey: String
    let modelName: String
    let authScheme: AuthScheme
    let urlSession: URLSession

    static let anthropicVersion = "2023-06-01"
    static let maxTokens = 8192

    // MARK: - Init

    public init(baseURL: String, apiKey: String, modelName: String, authScheme: AuthScheme = .xApiKey) {
        let base = URL(string: baseURL) ?? URL(string: "https://api.anthropic.com")!
        self.endpointURL = base.appendingPathComponent("v1/messages")
        self.apiKey = apiKey
        self.modelName = modelName
        self.authScheme = authScheme

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = AppConfig.shared.requestTimeoutSeconds
        config.timeoutIntervalForResource = AppConfig.shared.requestTimeoutSeconds
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - AIClientProtocol: validateProvider

    public func validateProvider() async throws {
        // Anthropic has no /models endpoint — send a minimal request to confirm auth.
        let body = AnthropicRequest(
            model: modelName.isEmpty ? "claude-3-haiku-20240307" : modelName,
            maxTokens: 1,
            system: nil,
            messages: [AnthropicMessage(role: "user", content: .text("hi"))],
            tools: nil,
            stream: false
        )
        let request = try buildRequest(body: body)
        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse else {
            throw ChappieError.networkError("Invalid response from Anthropic")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ChappieError.networkError("HTTP \(http.statusCode): Invalid API key or unauthorized.")
        }
        print("[AnthropicClient] Provider validated: \(endpointURL.host ?? "")")
        _ = data
    }

    // MARK: - AIClientProtocol: validateConnection

    public func validateConnection() async throws {
        let body = AnthropicRequest(
            model: modelName,
            maxTokens: 1,
            system: nil,
            messages: [AnthropicMessage(role: "user", content: .text("hi"))],
            tools: nil,
            stream: false
        )
        let request = try buildRequest(body: body)
        let (data, response) = try await performRequest(request)
        try validateHTTPResponse(response, data: data)
        print("[AnthropicClient] Connection validated: \(endpointURL.host ?? "") / \(modelName)")
    }

    // MARK: - AIClientProtocol: fetchAvailableModels

    public func fetchAvailableModels() async -> [String] { [] }

    // MARK: - AIClientProtocol: sendRequest

    public func sendRequest(
        systemPrompt: String,
        chatHistory: [AIMessage],
        tools: [AITool]
    ) async throws -> (message: AIMessage, cost: Double?, balance: Double?) {
        let anthropicMessages = buildAnthropicMessages(from: chatHistory)
        let anthropicTools = tools.isEmpty ? nil : tools.map(convertTool)

        let body = AnthropicRequest(
            model: modelName,
            maxTokens: Self.maxTokens,
            system: systemPrompt.isEmpty ? nil : systemPrompt,
            messages: anthropicMessages,
            tools: anthropicTools,
            stream: false
        )

        let request = try buildRequest(body: body)
        let (data, response) = try await performRequest(request)
        try validateHTTPResponse(response, data: data)

        struct AnthropicResponse: Decodable {
            struct ContentBlock: Decodable {
                let type: String
                let text: String?
            }
            let content: [ContentBlock]
            let usage: AnthropicUsage?
        }

        let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        let text = decoded.content.compactMap { $0.text }.joined()
        let message = AIMessage(role: "assistant", content: text)
        return (message, decoded.usage?.costRub, decoded.usage?.balance)
    }

    // MARK: - HTTP Helpers

    func buildRequest(body: AnthropicRequest) throws -> URLRequest {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")

        // x-api-key for native Anthropic, Bearer for proxies, none for open endpoints.
        switch authScheme {
        case .xApiKey:
            request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        case .bearer:
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .none:
            break
        }

        request.timeoutInterval = AppConfig.shared.requestTimeoutSeconds
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw ChappieError.parsingError("Failed to serialize Anthropic request: \(error.localizedDescription)")
        }
        return request
    }

    func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await urlSession.data(for: request)
        } catch {
            let nsError = error as NSError
            if nsError.code == NSURLErrorTimedOut {
                throw ChappieError.networkError("Request timed out (\(Int(AppConfig.shared.requestTimeoutSeconds))s).")
            }
            throw ChappieError.networkError("Request failed: \(error.localizedDescription)")
        }
    }

    func validateHTTPResponse(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ChappieError.networkError("Invalid response type")
        }
        guard !(200...299).contains(http.statusCode) else { return }
        throw LLMHTTP.error(for: http, body: data)
    }
}
