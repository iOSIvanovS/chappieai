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
    /// Caching routes: placement comes from OpenAICacheSettings (default `explicit`: breakpoints on the
    /// system prompt and on the last message before the screen frame). The parameter default below is
    /// the plain layout, used by the connection check where caching is irrelevant.
    /// Strict providers (supportsCaching=false): all messages normalized to plain strings.
    func buildMessages(
        systemPrompt: String,
        chatHistory: [AIMessage],
        cacheSettings: OpenAICacheSettings = OpenAICacheSettings(placement: .topLevel, sendSessionID: false)
    ) -> [AIMessage] {
        let explicit = supportsCaching && cacheSettings.placement == .explicit

        // topLevel: plain system message, the request-level cache_control covers everything.
        // explicit: the system prompt carries its own breakpoint, the stable head of every request.
        let systemMessage = explicit
            ? AIMessage(role: "system", contentBlocks: [AIContentBlock(text: systemPrompt, cacheControl: .oneHour)])
            : AIMessage(role: "system", content: systemPrompt)

        var messages: [AIMessage] = [systemMessage]

        // The live screen frame travels under its own role. It is the last user turn here, and in
        // explicit mode the breakpoint is placed BEFORE it, so the picture that vanishes on the
        // next step is never part of a written cache entry.
        let marked = explicit ? OpenAICacheBreakpoints.marking(chatHistory) : chatHistory
        let history = marked.map(asUserTurnIfScreenFrame)

        if supportsCaching {
            messages.append(contentsOf: history)
        } else {
            messages.append(contentsOf: history.compactMap { normalizeMessage($0) })
        }

        print("[AIClient] Request: 1 system + \(chatHistory.count) msgs → \(endpointURL.host ?? "") / \(modelName)")
        return messages
    }

    /// ScreenFrame.role is an internal marker, not a wire role: OpenAI-compatible APIs know
    /// system/user/assistant/tool only and would reject anything else.
    private func asUserTurnIfScreenFrame(_ message: AIMessage) -> AIMessage {
        guard message.role == ScreenFrame.role else { return message }
        var copy = message
        copy.role = "user"
        return copy
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
        let costStr = usage.effectiveCost.map { String(format: "%.4f RUB", $0) } ?? "n/a"

        if cacheRead > 0 {
            let pct = promptTokens > 0 ? Int(Double(cacheRead) / Double(promptTokens) * 100) : 0
            let savings = Int(Double(cacheRead) * 0.9)
            print("[AIClient] CACHE HIT | prompt: \(promptTokens) | read: \(cacheRead) (~\(savings) saved, \(pct)%) | created: \(cacheCreation) | completion: \(completionTokens) | cost: \(costStr)")
        } else if cacheCreation > 0 {
            print("[AIClient] CACHE WRITE | prompt: \(promptTokens) | created: \(cacheCreation) | completion: \(completionTokens) | cost: \(costStr)")
        } else {
            print("[AIClient] CACHE MISS | prompt: \(promptTokens) | completion: \(completionTokens) | cost: \(costStr)")
        }
        print("[RequestTrace] \(LogClock.stamp()) RESPONSE openai"
              + " | read \(cacheRead) | wrote \(cacheCreation)"
              + " | prompt \(promptTokens) | out \(completionTokens)")
    }

    // MARK: - HTTP Helpers

    func buildURLRequest(body: AITunnelRequest) throws -> URLRequest {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        if let session = body.session_id { request.addValue(session, forHTTPHeaderField: "x-session-id") }
        request.timeoutInterval = AppConfig.shared.requestTimeoutSeconds
        do {
            // Sorted keys for the same reason as in AnthropicClient.buildRequest: JSONEncoder's
            // dictionary order is seeded per process, so an unsorted body differs after every
            // relaunch and any prefix cache on this route would never be read back.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(body)
            request.httpBody = encoded
            RequestTrace.log(body: encoded, route: "openai")
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
        // Typed error: the retry layer classifies by status code (500/429 retry, 401/400 do not).
        throw LLMHTTP.error(for: http, body: data)
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
        return (choice.message, result.usage?.effectiveCost, result.usage?.balance)
    }
}
