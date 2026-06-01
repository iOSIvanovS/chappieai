//
//  AITunnelClient.swift
//  ChappieCore
//
//  Lightweight network client for AITunnel (OpenAI-compatible) API.
//

import Foundation

/// Lightweight HTTP client for AITunnel API requests.
public struct AITunnelClient: Sendable {

    private let endpointURL = URL(string: "https://api.aitunnel.ru/v1/chat/completions")!
    private let apiKey: String
    private let modelName: String
    /// Custom URLSession with extended timeouts from AppConfig.
    private let urlSession: URLSession

    public init(apiKey: String, modelName: String = "claude-sonnet-4.6") {
        self.apiKey = apiKey
        self.modelName = modelName

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = AppConfig.shared.requestTimeoutSeconds
        config.timeoutIntervalForResource = AppConfig.shared.requestTimeoutSeconds
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Non-streaming request — fallback for when streaming is unavailable.
    public func sendRequest(
        systemPrompt: String,
        chatHistory: [AIMessage],
        tools: [AITool]
    ) async throws -> (message: AIMessage, cost: Double?, balance: Double?) {

        let messages = buildMessages(systemPrompt: systemPrompt, chatHistory: chatHistory)
        let requestBody = AITunnelRequest(
            model: modelName, messages: messages, temperature: 0.7,
            tools: tools.isEmpty ? nil : tools, stream: false
        )

        let request = try buildURLRequest(body: requestBody)
        let (data, response) = try await performRequest(request)
        try validateHTTPResponse(response, data: data)

        let result = try decodeResponse(data)
        logCacheStats(usage: result.usage)

        guard let choice = result.choices.first else {
            throw ChappieError.parsingError("Model returned empty choices array")
        }

        return (choice.message, result.usage?.cost_rub, result.usage?.balance)
    }

    /// Primary streaming request with tool-call support.
    public func streamRequestWithTools(
        systemPrompt: String,
        chatHistory: [AIMessage],
        tools: [AITool],
        onToken: (@Sendable (String) -> Void)? = nil
    ) async throws -> AIStreamResult {

        let messages = buildMessages(systemPrompt: systemPrompt, chatHistory: chatHistory)
        let requestBody = AITunnelRequest(
            model: modelName, messages: messages, temperature: 0.7,
            tools: tools.isEmpty ? nil : tools, stream: true
        )

        let request = try buildURLRequest(body: requestBody)

        let asyncBytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (asyncBytes, response) = try await urlSession.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw ChappieError.cancelled
        }

        try validateHTTPResponse(response, data: nil)

        var accumulatedText = ""
        var toolCallBuffers: [Int: (id: String, name: String, arguments: String)] = [:]
        var finalCost: Double? = nil
        var finalBalance: Double? = nil

        do {
            for try await line in asyncBytes.lines {
                guard !line.isEmpty, line.hasPrefix("data: ") else { continue }

                let jsonString = String(line.dropFirst(6))
                if jsonString == "[DONE]" { break }

                guard let chunkData = jsonString.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(AIStreamChunk.self, from: chunkData) else {
                    continue
                }

                if let usage = chunk.usage {
                    finalCost = usage.cost_rub
                    finalBalance = usage.balance
                    logCacheStats(usage: usage)
                }

                guard let choice = chunk.choices.first else { continue }
                let delta = choice.delta

                if let token = delta.content, !token.isEmpty {
                    accumulatedText += token
                    onToken?(token)
                }

                if let streamToolCalls = delta.tool_calls {
                    for streamToolCall in streamToolCalls {
                        let idx = streamToolCall.index
                        if var existing = toolCallBuffers[idx] {
                            if let argChunk = streamToolCall.function?.arguments {
                                existing.arguments += argChunk
                                toolCallBuffers[idx] = existing
                            }
                        } else {
                            let id = streamToolCall.id ?? "call_\(idx)"
                            let name = streamToolCall.function?.name ?? ""
                            let args = streamToolCall.function?.arguments ?? ""
                            toolCallBuffers[idx] = (id: id, name: name, arguments: args)
                        }
                    }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw ChappieError.cancelled
        }

        let assembledToolCalls: [AIToolCall]? = toolCallBuffers.isEmpty ? nil :
            toolCallBuffers.sorted(by: { $0.key < $1.key }).compactMap { (_, buffer) in
                guard !buffer.name.isEmpty else { return nil }
                return AIToolCall(
                    id: buffer.id, type: "function",
                    function: AIToolCallFunction(name: buffer.name, arguments: buffer.arguments)
                )
            }

        return AIStreamResult(
            text: accumulatedText, toolCalls: assembledToolCalls,
            cost: finalCost, balance: finalBalance
        )
    }

    /// Legacy streaming without tools — kept for backward compatibility.
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

        let getUsage: @Sendable () async -> (cost: Double?, balance: Double?) = {
            await usageBox.get()
        }

        return (stream, getUsage)
    }

    // MARK: - Private: message building

    private func buildMessages(systemPrompt: String, chatHistory: [AIMessage]) -> [AIMessage] {
        var messages: [AIMessage] = [AIMessage(role: "system", content: systemPrompt)]
        messages.append(contentsOf: chatHistory)
        print("[AITunnelClient] 📤 Request: 1 system + \(chatHistory.count) history messages")
        return messages
    }

    // MARK: - Private: cache diagnostics

    /// Logs prompt-cache stats to help diagnose whether tools are cached alongside the system prompt.
    /// coverage% = cache_read / prompt_tokens — aim for 80-100% to confirm tool caching.
    private func logCacheStats(usage: AIUsage?) {
        guard let usage else { return }

        let cacheRead        = usage.effectiveCacheRead
        let cacheCreation    = usage.effectiveCacheCreation
        let promptTokens     = usage.prompt_tokens ?? 0
        let completionTokens = usage.completion_tokens ?? 0
        let costStr          = usage.cost_rub.map { String(format: "%.4f ₽", $0) } ?? "n/a"

        let coverageStr: String
        if promptTokens > 0 && cacheRead > 0 {
            let pct = Int(Double(cacheRead) / Double(promptTokens) * 100)
            coverageStr = " | coverage: \(pct)%"
        } else {
            coverageStr = ""
        }

        if cacheRead > 0 {
            let savings = Int(Double(cacheRead) * 0.9)
            print("[AITunnelClient] ✅ CACHE HIT | prompt: \(promptTokens) tok | read: \(cacheRead) tok (~\(savings) saved)\(coverageStr) | created: \(cacheCreation) tok | completion: \(completionTokens) tok | cost: \(costStr)")
        } else if cacheCreation > 0 {
            print("[AITunnelClient] 🔄 CACHE WRITE | prompt: \(promptTokens) tok | created: \(cacheCreation) tok | completion: \(completionTokens) tok | cost: \(costStr)")
        } else {
            // No cache activity — possible causes: model doesn't support top-level cache_control,
            // too few tokens (<1024), or the gateway ignored the field.
            print("[AITunnelClient] ⚠️ CACHE MISS | prompt: \(promptTokens) tok | completion: \(completionTokens) tok | cost: \(costStr)")
        }
    }

    // MARK: - Private: request execution

    private func performStreamRequest(
        systemPrompt: String,
        chatHistory: [AIMessage],
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws -> (cost: Double?, balance: Double?) {

        let messages = buildMessages(systemPrompt: systemPrompt, chatHistory: chatHistory)
        let requestBody = AITunnelRequest(
            model: modelName, messages: messages, temperature: 0.7,
            tools: nil, stream: true
        )

        let request = try buildURLRequest(body: requestBody)
        let (asyncBytes, response) = try await urlSession.bytes(for: request)
        try validateHTTPResponse(response, data: nil)

        var finalCost: Double? = nil
        var finalBalance: Double? = nil

        for try await line in asyncBytes.lines {
            guard !line.isEmpty, line.hasPrefix("data: ") else { continue }

            let jsonString = String(line.dropFirst(6))
            if jsonString == "[DONE]" { break }

            guard let chunkData = jsonString.data(using: .utf8) else { continue }

            let chunk: AIStreamChunk
            do {
                chunk = try JSONDecoder().decode(AIStreamChunk.self, from: chunkData)
            } catch {
                continue
            }

            if let usage = chunk.usage {
                finalCost = usage.cost_rub
                finalBalance = usage.balance
            }

            guard let choice = chunk.choices.first else { continue }
            if let token = choice.delta.content, !token.isEmpty {
                continuation.yield(token)
            }
        }

        return (finalCost, finalBalance)
    }

    /// Builds URLRequest with auth headers and serialized JSON body.
    private func buildURLRequest(body: AITunnelRequest) throws -> URLRequest {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
                    "Request timed out (\(Int(AppConfig.shared.requestTimeoutSeconds))s). " +
                    "Task may be too complex or server is overloaded."
                )
            }
            throw ChappieError.networkError("Request failed: \(error.localizedDescription)")
        }
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data?) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChappieError.networkError("Invalid response type (not HTTPURLResponse)")
        }

        guard !(200...299).contains(httpResponse.statusCode) else { return }

        let errorBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? "No response body"

        let isContextError = httpResponse.statusCode == 413
            || errorBody.lowercased().contains("context")
            || errorBody.lowercased().contains("limit")
            || errorBody.lowercased().contains("too long")

        if isContextError {
            throw ChappieError.aiContextLimitExceeded
        }

        throw ChappieError.networkError("HTTP \(httpResponse.statusCode): \(errorBody)")
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

    func get() -> (cost: Double?, balance: Double?) {
        return (cost, balance)
    }
}
