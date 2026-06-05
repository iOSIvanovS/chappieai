// AIClient+HTTP.swift — auth, message building, HTTP helpers, cache stats
import Foundation

extension AIClient {

    // MARK: - Auth

    /// Applies the correct authorization header based on authScheme.
    /// .none — no header (local providers: Ollama, LM Studio).
    func applyAuth(to request: inout URLRequest) {
        switch authScheme {
        case .bearer:
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .xApiKey:
            request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        case .none:
            break
        }
    }

    // MARK: - Message Building

    /// Builds the final message array for the provider.
    ///
    /// AITunnel (supportsCaching=true): system prompt sent as content block array with
    /// cache_control — explicit breakpoint that works on Bedrock/Vertex too.
    /// Strict providers (supportsCaching=false): all messages normalized to plain strings.
    func buildMessages(systemPrompt: String, chatHistory: [AIMessage]) -> [AIMessage] {
        let systemMessage: AIMessage
        if supportsCaching {
            systemMessage = AIMessage(
                role: "system",
                contentBlocks: [AIContentBlock(text: systemPrompt, cacheControl: .oneHour)]
            )
        } else {
            systemMessage = AIMessage(role: "system", content: systemPrompt)
        }

        var messages: [AIMessage] = [systemMessage]

        if supportsCaching {
            messages.append(contentsOf: chatHistory)
        } else {
            messages.append(contentsOf: chatHistory.compactMap { normalizeMessage($0) })
        }

        print("[AIClient] Request: 1 system + \(chatHistory.count) msgs → \(endpointURL.host ?? "") / \(modelName)")
        return messages
    }

    /// Normalizes a message for strict OpenAI-compatible providers (Groq, Ollama, etc.).
    /// Returns nil for messages that should be dropped entirely.
    /// .blocks → joined plain string, .multimodal → text only (images dropped), .text("") → nil
    func normalizeMessage(_ message: AIMessage) -> AIMessage? {
        switch message.content {
        case .blocks(let blocks):
            let text = blocks.map(\.text).joined()
            guard !text.isEmpty else { return nil }
            return AIMessage(role: message.role, content: text, tool_calls: message.tool_calls, tool_call_id: message.tool_call_id, name: message.name)
        case .multimodal(let parts):
            let text = parts.compactMap { part -> String? in
                if case .text(let t) = part { return t }
                return nil
            }.joined(separator: "\n")
            guard !text.isEmpty else { return nil }
            return AIMessage(role: message.role, content: text, tool_calls: message.tool_calls, tool_call_id: message.tool_call_id, name: message.name)
        case .text(let s):
            if s.isEmpty {
                return AIMessage(role: message.role, content: nil as String?, tool_calls: message.tool_calls, tool_call_id: message.tool_call_id, name: message.name)
            }
            return message
        case .none:
            return message
        }
    }

    // MARK: - Cache Stats

    func logCacheStats(usage: AIUsage?) {
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

    // MARK: - HTTP Helpers

    func buildURLRequest(body: AITunnelRequest) throws -> URLRequest {
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

    func decodeResponse(_ data: Data) throws -> AITunnelResponse {
        do {
            return try JSONDecoder().decode(AITunnelResponse.self, from: data)
        } catch {
            throw ChappieError.parsingError("Failed to decode model response: \(error.localizedDescription)")
        }
    }

    // MARK: - Non-streaming (used by validateConnection)

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
            stream: false,
            cacheControl: nil
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
}
