// AnthropicClient.swift
// ChappieCore
//
// Native Anthropic API client — implements AIClientProtocol.
//
// WIRE FORMAT vs OpenAI:
// - Endpoint: POST <messagesPath> (native "/v1/messages"; a gateway may serve it on its own path)
// - System prompt: top-level "system" field as an array of blocks, so a cache breakpoint fits
// - Tool results: role "user" with content array of type "tool_result"
// - Tool calls: content array blocks of type "tool_use"
// - Streaming: event: content_block_delta / event: message_delta
// - Auth: x-api-key + anthropic-version header (or Bearer for proxies)
// - max_tokens is REQUIRED
// - No /v1/models endpoint — fetchAvailableModels() returns []
//
// PRICE: the native protocol has no cost field. A gateway that bills per request exposes it
// after the fact, keyed by the id it returns in the `x-generation-id` response header. The header
// is captured during the request and the price is fetched once the stream has finished, so a
// failed lookup can never break the turn.

import Foundation

public struct AnthropicClient: Sendable, AIClientProtocol {

    // MARK: - Configuration

    let endpointURL: URL
    let apiKey: String
    let modelName: String
    let authScheme: AuthScheme
    let urlSession: URLSession
    let supportsCaching: Bool
    /// Price lookup for gateways that bill per request; nil for the native Anthropic API.
    let costSource: (url: URL, endpoint: BalanceEndpoint)?
    /// Account balance after the turn; nil when the provider reports it inside chat responses.
    let balanceSource: (url: URL, endpoint: BalanceEndpoint)?
    let maxTokens: Int

    static let anthropicVersion = "2023-06-01"
    static let defaultMaxTokens = 8192
    /// 1h TTL needs the beta header; without it the gateway silently keeps the 5-minute default.
    static let cacheTTLHeader = "extended-cache-ttl-2025-04-11"
    static let cacheControl = AICacheControl(type: "ephemeral", ttl: "1h")

    // MARK: - Init

    public init(
        baseURL: String,
        apiKey: String,
        modelName: String,
        authScheme: AuthScheme = .xApiKey,
        messagesPath: String = "/v1/messages",
        supportsCaching: Bool = false,
        costSource: (url: URL, endpoint: BalanceEndpoint)? = nil,
        balanceSource: (url: URL, endpoint: BalanceEndpoint)? = nil,
        maxTokens: Int = 8192
    ) {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let path = messagesPath.hasPrefix("/") ? messagesPath : "/" + messagesPath
        self.endpointURL = URL(string: trimmed + path)
            ?? URL(string: "https://api.anthropic.com" + path)!
        self.apiKey = apiKey
        self.modelName = modelName
        self.authScheme = authScheme
        self.supportsCaching = supportsCaching
        self.costSource = costSource
        self.balanceSource = balanceSource
        self.maxTokens = maxTokens

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
        let anthropicMessages = applyingCacheBreakpoints(
            to: buildAnthropicMessages(from: chatHistory)
        )
        let anthropicTools = tools.isEmpty ? nil : tools.map(convertTool)

        let body = AnthropicRequest(
            model: modelName,
            maxTokens: maxTokens,
            system: buildSystemBlocks(systemPrompt),
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
        let cost = try await resolveCost(generationId: generationId(from: response))
        return (message, cost, await fetchBalance())
    }

    // MARK: - HTTP Helpers

    func buildRequest(body: AnthropicRequest) throws -> URLRequest {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        if supportsCaching {
            request.addValue(Self.cacheTTLHeader, forHTTPHeaderField: "anthropic-beta")
        }

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

    // MARK: - Price & Balance

    /// The gateway's billing id for this request. Nil on the native Anthropic API.
    func generationId(from response: URLResponse) -> String? {
        (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-generation-id")
    }

    /// Price of one request in the provider's currency (RUB for RouterAI).
    /// Never throws: a missing price must not break a finished turn — the UI keeps the old value.
    func resolveCost(generationId: String?) async throws -> Double? {
        guard let source = costSource, let id = generationId,
              var components = URLComponents(url: source.url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        applyAuth(to: &request)

        guard let (data, response) = try? await urlSession.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            print("[AnthropicClient] Price unavailable for generation \(id)")
            return nil
        }
        return source.endpoint.parse(data)
    }

    /// Account balance after the turn.
    func fetchBalance() async -> Double? {
        guard let source = balanceSource else { return nil }
        var request = URLRequest(url: source.url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        applyAuth(to: &request)
        guard let (data, response) = try? await urlSession.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return source.endpoint.parse(data)
    }

    func applyAuth(to request: inout URLRequest) {
        switch authScheme {
        case .xApiKey: request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        case .bearer:  request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .none:    break
        }
    }
}
