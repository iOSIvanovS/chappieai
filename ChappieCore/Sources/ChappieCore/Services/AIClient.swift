// AIClient.swift
// ChappieCore
//
// OpenAI-compatible streaming AI client.
// Implements AIClientProtocol — works with any provider that follows the
// OpenAI chat completions API (/v1/chat/completions).
//
// STALL-WATCHDOG:
// streamRequestWithTools() launches a child Task for the stream loop.
// StallWatchdog monitors token arrival. If no token arrives within stallTimeout
// seconds — it cancels the child Task and throws StallError.
//
// CANCEL FIX:
// asyncBytes.lines does NOT respect cooperative Swift cancellation while waiting for
// server bytes. Fix: check Task.isCancelled on every iteration.
//
// AUTH SCHEME:
// Supports both Bearer and x-api-key auth headers.
// Controlled by AuthScheme passed at init — allows OpenAI-format body with x-api-key
// or any other combination needed by proxy providers.
//
// URL DESIGN:
// Two inits exist to avoid double-path bugs:
//   init(endpoint:) — for chat requests. baseURL is derived by stripping the path.
//   init(baseURL:)  — for discovery/validation. endpointURL = baseURL + /v1/chat/completions.
// fetchAvailableModels and validateProvider always use baseURL.appendingPathComponent("v1/models").
// This means callers must pass the correct base (e.g. "https://openrouter.ai/api"),
// NOT the full models URL.

import Foundation

// MARK: - StallError

/// Thrown by streamRequestWithTools() when no tokens arrive within stallTimeout seconds.
///
/// Distinct from CancellationError (user cancel) and URLError (network failure).
/// AIOrchestrator catches this specifically to perform a continuation retry.
public struct StallError: Error, Sendable {
    public let stallSeconds: TimeInterval
    public let partialText: String

    public init(stallSeconds: TimeInterval, partialText: String) {
        self.stallSeconds = stallSeconds
        self.partialText = partialText
    }
}

// MARK: - AIClient

/// OpenAI-compatible streaming AI client.
///
/// Supports: streaming, tool calls, prompt caching stats, connection validation.
/// Use AIClientFactory.make() to get the right client for a given provider+model.
public struct AIClient: Sendable, AIClientProtocol {

    // MARK: - Configuration

    /// Full chat completions endpoint URL, e.g. "https://api.openai.com/v1/chat/completions"
    private let endpointURL: URL

    /// Base URL for auxiliary requests — scheme+host+prefix, e.g. "https://openrouter.ai/api"
    /// fetchAvailableModels appends "/v1/models" to this, validateProvider does the same.
    private let baseURL: URL

    private let apiKey: String
    private let modelName: String
    private let authScheme: AuthScheme
    private let urlSession: URLSession

    // MARK: - Init (from chat endpoint)

    /// Use when you have the full chat endpoint URL.
    /// baseURL is derived by stripping the path — works for simple providers (OpenAI, AITunnel).
    /// For providers with path prefixes (OpenRouter: /api/v1/...) use init(baseURL:) instead.
    public init(endpoint: String, apiKey: String, modelName: String, authScheme: AuthScheme = .bearer) {
        self.endpointURL = URL(string: endpoint) ?? URL(string: "https://api.openai.com/v1/chat/completions")!
        self.apiKey = apiKey
        self.modelName = modelName
        self.authScheme = authScheme

        // Derive base URL: strip path to get scheme+host only
        if let url = URL(string: endpoint), let scheme = url.scheme, let host = url.host {
            let port = url.port.map { ":\($0)" } ?? ""
            self.baseURL = URL(string: "\(scheme)://\(host)\(port)") ?? url
        } else {
            self.baseURL = self.endpointURL
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = AppConfig.shared.requestTimeoutSeconds
        config.timeoutIntervalForResource = AppConfig.shared.requestTimeoutSeconds
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Init (from base URL)

    /// Use for discovery/validation when you know the provider's base URL (e.g. "https://openrouter.ai/api").
    /// endpointURL = baseURL + /v1/chat/completions.
    /// fetchAvailableModels and validateProvider append /v1/models to baseURL directly — no double-path.
    public init(baseURL: String, apiKey: String, modelName: String, authScheme: AuthScheme = .bearer) {
        let base = URL(string: baseURL) ?? URL(string: "https://api.openai.com")!
        self.baseURL = base
        self.endpointURL = base.appendingPathComponent("v1/chat/completions")
        self.apiKey = apiKey
        self.modelName = modelName
        self.authScheme = authScheme

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = AppConfig.shared.requestTimeoutSeconds
        config.timeoutIntervalForResource = AppConfig.shared.requestTimeoutSeconds
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - AIClientProtocol: fetchAvailableModels

    public func fetchAvailableModels() async -> [String] {
        let modelsURL = baseURL.appendingPathComponent("v1/models")
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        applyAuth(to: &request)
        request.timeoutInterval = 15

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return [] }

            struct ModelsResponse: Decodable {
                struct ModelObject: Decodable { let id: String }
                let data: [ModelObject]
            }

            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return decoded.data.map { $0.id }.sorted()
        } catch {
            print("[AIClient] fetchAvailableModels failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - AIClientProtocol: validateProvider

    public func validateProvider() async throws {
        let modelsURL = baseURL.appendingPathComponent("v1/models")
        var req = URLRequest(url: modelsURL)
        req.httpMethod = "GET"
        applyAuth(to: &req)
        req.timeoutInterval = 15

        do {
            let (_, response) = try await urlSession.data(for: req)
            guard let http = response as? HTTPURLResponse else { return }

            if http.statusCode == 401 || http.statusCode == 403 {
                throw ChappieError.networkError("HTTP \(http.statusCode): Invalid API key or unauthorized.")
            }
            print("[AIClient] Provider validated (HTTP \(http.statusCode)): \(baseURL.host ?? "")")
        } catch let error as ChappieError {
            throw error
        } catch {
            throw ChappieError.networkError("Cannot reach provider: \(error.localizedDescription)")
        }
    }

    // MARK: - AIClientProtocol: validateConnection

    public func validateConnection() async throws {
        let body = AITunnelRequest(
            model: modelName,
            messages: [AIMessage(role: "user", content: "hi")],
            temperature: 0.1,
            tools: nil,
            stream: false
        )
        let request = try buildURLRequest(body: body)
        let (data, response) = try await performRequest(request)
        try validateHTTPResponse(response, data: data)
        print("[AIClient] Connection validated: \(endpointURL.host ?? "") / \(modelName)")
    }

    // MARK: - AIClientProtocol: streamRequestWithTools

    public func streamRequestWithTools(
        systemPrompt: String,
        chatHistory: [AIMessage],
        tools: [AITool],
        stallTimeout: TimeInterval = AppConfig.shared.stallTimeoutSeconds,
        onToken: (@Sendable (String) -> Void)? = nil
    ) async throws -> AIStreamResult {

        try Task.checkCancellation()

        let messages = buildMessages(systemPrompt: systemPrompt, chatHistory: chatHistory)
        let body = AITunnelRequest(
            model: modelName,
            messages: messages,
            temperature: 0.7,
            tools: tools.isEmpty ? nil : tools,
            stream: true
        )

        let request = try buildURLRequest(body: body)

        let asyncBytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (asyncBytes, response) = try await urlSession.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw ChappieError.cancelled
        }

        try Task.checkCancellation()
        try validateHTTPResponse(response, data: nil)

        final class StreamState: @unchecked Sendable {
            var accumulatedText = ""
            var toolCallBuffers: [Int: (id: String, name: String, arguments: String)] = [:]
            var finalCost: Double? = nil
            var finalBalance: Double? = nil
        }
        let state = StreamState()
        let watchdog = StallWatchdog(timeout: stallTimeout)

        let streamTask = Task {
            await watchdog.start()

            for try await line in asyncBytes.lines {
                if Task.isCancelled { break }
                await watchdog.reset()

                guard !line.isEmpty, line.hasPrefix("data: ") else { continue }
                let jsonString = String(line.dropFirst(6))
                if jsonString == "[DONE]" { break }

                guard let chunkData = jsonString.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(AIStreamChunk.self, from: chunkData) else {
                    continue
                }

                if let usage = chunk.usage {
                    state.finalCost = usage.cost_rub
                    state.finalBalance = usage.balance
                    logCacheStats(usage: usage)
                }

                guard let choice = chunk.choices.first else { continue }
                let delta = choice.delta

                if let token = delta.content, !token.isEmpty {
                    state.accumulatedText += token
                    onToken?(token)
                }

                if let streamToolCalls = delta.tool_calls {
                    for tc in streamToolCalls {
                        let idx = tc.index
                        if var existing = state.toolCallBuffers[idx] {
                            if let arg = tc.function?.arguments {
                                existing.arguments += arg
                                state.toolCallBuffers[idx] = existing
                            }
                        } else {
                            state.toolCallBuffers[idx] = (
                                id: tc.id ?? "call_\(idx)",
                                name: tc.function?.name ?? "",
                                arguments: tc.function?.arguments ?? ""
                            )
                        }
                    }
                }
            }

            await watchdog.stop()
        }

        do {
            try await streamTask.value
        } catch is CancellationError {
            if await watchdog.isStalled {
                print("[AIClient] Stall after \(stallTimeout)s. Partial: \(state.accumulatedText.count) chars.")
                throw StallError(stallSeconds: stallTimeout, partialText: state.accumulatedText)
            }
            print("[AIClient] Stream cancelled by user.")
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            if await watchdog.isStalled {
                throw StallError(stallSeconds: stallTimeout, partialText: state.accumulatedText)
            }
            throw ChappieError.cancelled
        } catch {
            throw error
        }

        let assembledToolCalls: [AIToolCall]? = state.toolCallBuffers.isEmpty ? nil :
            state.toolCallBuffers.sorted(by: { $0.key < $1.key }).compactMap { (_, buf) in
                guard !buf.name.isEmpty else { return nil }
                return AIToolCall(
                    id: buf.id,
                    type: "function",
                    function: AIToolCallFunction(name: buf.name, arguments: buf.arguments)
                )
            }

        return AIStreamResult(
            text: state.accumulatedText,
            toolCalls: assembledToolCalls,
            cost: state.finalCost,
            balance: state.finalBalance
        )
    }

    // MARK: - Non-streaming

    public func sendRequest(
        systemPrompt: String,
        chatHistory: [AIMessage],
        tools: [AITool]
    ) async throws -> (message: AIMessage, cost: Double?, balance: Double?) {
        let messages = buildMessages(systemPrompt: systemPrompt, chatHistory: chatHistory)
        let body = AITunnelRequest(
            model: modelName,
            messages: messages,
            temperature: 0.7,
            tools: tools.isEmpty ? nil : tools,
            stream: false
        )
        let request = try buildURLRequest(body: body)
        let (data, response) = try await performRequest(request)
        try validateHTTPResponse(response, data: data)
        let result = try decodeResponse(data)
        logCacheStats(usage: result.usage)
        guard let choice = result.choices.first else {
            throw ChappieError.parsingError("Model returned empty choices array")
        }
        return (choice.message, result.usage?.cost_rub, result.usage?.balance)
    }

    // MARK: - Legacy streaming (deprecated)

    public func streamRequest(
        systemPrompt: String,
        chatHistory: [AIMessage]
    ) -> (stream: AsyncThrowingStream<String, Error>, getUsage: @Sendable () async -> (cost: Double?, balance: Double?)) {
        let usageBox = UsageBox()
        let stream = AsyncThrowingStream<String, Error> { continuation in
            Task {
                do {
                    let usage = try await self.performStreamRequest(
                        systemPrompt: systemPrompt,
                        chatHistory: chatHistory,
                        continuation: continuation
                    )
                    await usageBox.set(usage)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        let getUsage: @Sendable () async -> (cost: Double?, balance: Double?) = { await usageBox.get() }
        return (stream, getUsage)
    }

    // MARK: - Private: Auth Header

    /// Applies the correct authorization header based on authScheme.
    private func applyAuth(to request: inout URLRequest) {
        switch authScheme {
        case .bearer:
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .xApiKey:
            request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
    }

    // MARK: - Private: Message Building

    private func buildMessages(systemPrompt: String, chatHistory: [AIMessage]) -> [AIMessage] {
        var messages: [AIMessage] = [AIMessage(role: "system", content: systemPrompt)]
        messages.append(contentsOf: chatHistory)
        print("[AIClient] Request: 1 system + \(chatHistory.count) msgs → \(endpointURL.host ?? "") / \(modelName)")
        return messages
    }

    // MARK: - Private: Cache Stats

    private func logCacheStats(usage: AIUsage?) {
        guard let usage else { return }
        let cacheRead = usage.effectiveCacheRead
        let cacheCreation = usage.effectiveCacheCreation
        let promptTokens = usage.prompt_tokens ?? 0
        let completionTokens = usage.completion_tokens ?? 0
        let costStr = usage.cost_rub.map { String(format: "%.4f RUB", $0) } ?? "n/a"

        if cacheRead > 0 {
            let pct = promptTokens > 0 ? Int(Double(cacheRead) / Double(promptTokens) * 100) : 0
            let savings = Int(Double(cacheRead) * 0.9)
            print("[AIClient] CACHE HIT | prompt: \(promptTokens) | read: \(cacheRead) (~\(savings) saved, \(pct)%) | created: \(cacheCreation) | completion: \(completionTokens) | cost: \(costStr)")
        } else if cacheCreation > 0 {
            print("[AIClient] CACHE WRITE | prompt: \(promptTokens) | created: \(cacheCreation) | completion: \(completionTokens) | cost: \(costStr)")
        } else {
            print("[AIClient] CACHE MISS | prompt: \(promptTokens) | completion: \(completionTokens) | cost: \(costStr)")
        }
    }

    // MARK: - Private: Legacy Stream

    private func performStreamRequest(
        systemPrompt: String,
        chatHistory: [AIMessage],
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws -> (cost: Double?, balance: Double?) {
        let messages = buildMessages(systemPrompt: systemPrompt, chatHistory: chatHistory)
        let body = AITunnelRequest(model: modelName, messages: messages, temperature: 0.7, tools: nil, stream: true)
        let request = try buildURLRequest(body: body)
        let (asyncBytes, response) = try await urlSession.bytes(for: request)
        try validateHTTPResponse(response, data: nil)

        var finalCost: Double? = nil
        var finalBalance: Double? = nil

        for try await line in asyncBytes.lines {
            guard !line.isEmpty, line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            if jsonString == "[DONE]" { break }
            guard let chunkData = jsonString.data(using: .utf8) else { continue }
            guard let chunk = try? JSONDecoder().decode(AIStreamChunk.self, from: chunkData) else { continue }
            if let usage = chunk.usage { finalCost = usage.cost_rub; finalBalance = usage.balance }
            guard let choice = chunk.choices.first else { continue }
            if let token = choice.delta.content, !token.isEmpty { continuation.yield(token) }
        }

        return (finalCost, finalBalance)
    }

    // MARK: - Private: HTTP Helpers

    private func buildURLRequest(body: AITunnelRequest) throws -> URLRequest {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.timeoutInterval = AppConfig.shared.requestTimeoutSeconds
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw ChappieError.parsingError("Failed to serialize request body: \(error.localizedDescription)")
        }
        return request
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await urlSession.data(for: request)
        } catch {
            let nsError = error as NSError
            if nsError.code == NSURLErrorTimedOut {
                throw ChappieError.networkError(
                    "Request timed out (\(Int(AppConfig.shared.requestTimeoutSeconds))s)."
                )
            }
            throw ChappieError.networkError("Request failed: \(error.localizedDescription)")
        }
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ChappieError.networkError("Invalid response type (not HTTPURLResponse)")
        }
        guard !(200...299).contains(http.statusCode) else { return }

        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "No response body"
        let isContextError = http.statusCode == 413
            || body.lowercased().contains("context")
            || body.lowercased().contains("limit")
            || body.lowercased().contains("too long")

        if isContextError { throw ChappieError.aiContextLimitExceeded }
        throw ChappieError.networkError("HTTP \(http.statusCode): \(body)")
    }

    private func decodeResponse(_ data: Data) throws -> AITunnelResponse {
        do {
            return try JSONDecoder().decode(AITunnelResponse.self, from: data)
        } catch {
            throw ChappieError.parsingError("Failed to decode model response: \(error.localizedDescription)")
        }
    }
}

// MARK: - UsageBox

private actor UsageBox {
    private var cost: Double? = nil
    private var balance: Double? = nil

    func set(_ usage: (cost: Double?, balance: Double?)) {
        self.cost = usage.cost
        self.balance = usage.balance
    }

    func get() -> (cost: Double?, balance: Double?) { (cost, balance) }
}
