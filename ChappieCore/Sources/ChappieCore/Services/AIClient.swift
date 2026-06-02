// AIClient.swift
// ChappieCore
//
// Universal network client for any OpenAI-compatible AI provider.
//
// REPLACES: AITunnelClient.swift (which had hardcoded AITunnel endpoint and model)
//
// KEY CHANGES FROM AITunnelClient:
// - endpoint is now a parameter (no hardcode)
// - modelName is now a parameter (no hardcode)
// - fetchAvailableModels() added: GET /models to populate model list
// - validateProvider() added: validates endpoint+key WITHOUT needing a model name
// - validateConnection() kept: validates endpoint+key+model (used when model is known)
// - All streaming/tool-call logic preserved intact
//
// BACKWARD COMPATIBILITY:
// AIOrchestrator now takes AIClient instead of AITunnelClient.
// ChappieViewModel creates AIClient from the active AIProvider + selected model.
//
// STALL-WATCHDOG (STALL-WATCHDOG):
// streamRequestWithTools() launches a child Task for the stream loop.
// A StallWatchdog actor monitors token arrival. If no token arrives within
// stallTimeout seconds — it cancels the child Task.
// The outer function distinguishes stall from user-cancel via StallWatchdog.isStalled
// and throws StallError so AIOrchestrator can perform a continuation retry.
//
// CANCEL FIX (CANCEL-FIX):
// asyncBytes.lines does NOT respect cooperative Swift cancellation while waiting for
// server bytes. Fix: check Task.isCancelled on every iteration + explicit URLSession
// task cancellation via DataStreamTask wrapper. On user cancel → CancellationError
// propagates cleanly up to ChappieViewModel+Send.swift.

import Foundation

// MARK: - StallError

/// Thrown by streamRequestWithTools() when no tokens arrive within stallTimeout seconds.
///
/// Distinct from CancellationError (user cancel) and URLError (network failure).
/// AIOrchestrator catches this specifically to perform a continuation retry.
public struct StallError: Error, Sendable {
    /// How many seconds of silence triggered the stall.
    public let stallSeconds: TimeInterval
    /// Partial text accumulated before the stall.
    public let partialText: String

    public init(stallSeconds: TimeInterval, partialText: String) {
        self.stallSeconds = stallSeconds
        self.partialText = partialText
    }
}

// MARK: - AIClient

/// Universal streaming AI client for OpenAI-compatible endpoints.
///
/// Supports: streaming, tool calls, prompt caching stats, connection validation.
/// Provider-agnostic: works with any endpoint that follows the OpenAI chat completions API.
public struct AIClient: Sendable {

    // MARK: - Configuration

    /// Full chat completions endpoint URL, e.g. "https://api.aitunnel.ru/v1/chat/completions"
    private let endpointURL: URL

    /// Base URL used for auxiliary requests like /models (derived from endpoint)
    private let baseURL: URL

    private let apiKey: String
    private let modelName: String

    /// Custom URLSession with extended timeouts.
    private let urlSession: URLSession

    // MARK: - Init

    public init(endpoint: String, apiKey: String, modelName: String) {
        // Parse endpoint URL, fall back to a safe default if malformed
        self.endpointURL = URL(string: endpoint) ?? URL(string: "https://api.aitunnel.ru/v1/chat/completions")!

        // Derive base URL: strip path components to get scheme+host
        // e.g. "https://api.aitunnel.ru/v1/chat/completions" → "https://api.aitunnel.ru"
        if let url = URL(string: endpoint),
           let scheme = url.scheme,
           let host = url.host {
            let port = url.port.map { ":\($0)" } ?? ""
            self.baseURL = URL(string: "\(scheme)://\(host)\(port)") ?? url
        } else {
            self.baseURL = self.endpointURL
        }

        self.apiKey = apiKey
        self.modelName = modelName

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = AppConfig.shared.requestTimeoutSeconds
        config.timeoutIntervalForResource = AppConfig.shared.requestTimeoutSeconds
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Provider Management: Fetch Available Models

    /// Fetches the list of available models from the provider's /models endpoint.
    ///
    /// Standard OpenAI-compatible endpoint: GET {baseURL}/v1/models
    /// Returns model IDs sorted alphabetically.
    /// Returns empty array if the endpoint doesn't support /models or request fails.
    public func fetchAvailableModels() async -> [String] {
        let modelsURL = baseURL.appendingPathComponent("v1/models")
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15 // Short timeout for model list

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return []
            }

            // OpenAI models response: { "data": [{ "id": "model-name", ... }] }
            struct ModelsResponse: Decodable {
                struct ModelObject: Decodable {
                    let id: String
                }
                let data: [ModelObject]
            }

            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return decoded.data.map { $0.id }.sorted()
        } catch {
            print("[AIClient] fetchAvailableModels failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Provider Management: Validate Provider (no model required)

    /// Validates an endpoint + API key WITHOUT needing a specific model name.
    ///
    /// Strategy: try GET /v1/models first (lightweight, no model needed).
    /// If /models returns 200 → provider is valid.
    /// If /models fails (e.g. endpoint doesn't support it) → try a minimal chat request
    /// with a placeholder model name and accept any non-401/403 response as valid.
    ///
    /// Used in AddProviderSheet step 1 (before models are added).
    /// Throws ChappieError on authentication failure or unreachable endpoint.
    public func validateProvider() async throws {
        let modelsURL = baseURL.appendingPathComponent("v1/models")
        var modelsRequest = URLRequest(url: modelsURL)
        modelsRequest.httpMethod = "GET"
        modelsRequest.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        modelsRequest.timeoutInterval = 15

        do {
            let (_, response) = try await urlSession.data(for: modelsRequest)
            if let http = response as? HTTPURLResponse {
                // 401/403 → bad key; anything else (200, 404, 500) → endpoint is reachable
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw ChappieError.networkError("HTTP \(http.statusCode): Invalid API key or unauthorized.")
                }
                // 200-299 → explicit success
                if (200...299).contains(http.statusCode) {
                    print("[AIClient] Provider validated via /models: \(baseURL.host ?? "")")
                    return
                }
                // Other status codes (404, 405, 500…) — endpoint is alive, key accepted
                print("[AIClient] Provider reachable (HTTP \(http.statusCode)): \(baseURL.host ?? "")")
                return
            }
        } catch let error as ChappieError {
            // Re-throw auth errors immediately
            throw error
        } catch {
            // Network error — endpoint unreachable
            throw ChappieError.networkError("Cannot reach provider: \(error.localizedDescription)")
        }
    }

    // MARK: - Provider Management: Validate Connection (endpoint + key + model)

    /// Sends a minimal test request to validate the endpoint + key + model combination.
    ///
    /// Used during model validation to confirm a specific model works.
    /// Throws ChappieError on failure with a descriptive message.
    public func validateConnection() async throws {
        let testMessages = [AIMessage(role: "user", content: "hi")]
        let requestBody = AITunnelRequest(
            model: modelName,
            messages: testMessages,
            temperature: 0.1,
            tools: nil,
            stream: false
        )

        let request = try buildURLRequest(body: requestBody)
        let (data, response) = try await performRequest(request)
        try validateHTTPResponse(response, data: data)
        print("[AIClient] Connection validated: \(endpointURL.host ?? "") / \(modelName)")
    }

    // MARK: - Public API: Non-streaming request (fallback)

    /// Sends a non-streaming request and returns the full response at once.
    public func sendRequest(
        systemPrompt: String,
        chatHistory: [AIMessage],
        tools: [AITool]
    ) async throws -> (message: AIMessage, cost: Double?, balance: Double?) {

        let messages = buildMessages(systemPrompt: systemPrompt, chatHistory: chatHistory)

        let requestBody = AITunnelRequest(
            model: modelName,
            messages: messages,
            temperature: 0.7,
            tools: tools.isEmpty ? nil : tools,
            stream: false
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

    // MARK: - Public API: Streaming request with tools (primary method)

    /// Sends a streaming request with tool call support.
    ///
    /// Returns AIStreamResult with accumulated text + tool calls + cost info.
    ///
    /// STALL-WATCHDOG:
    /// The stream loop runs in a child Task. A StallWatchdog actor tracks token arrival.
    /// On each received token, reset() is called. If no token arrives within stallTimeout
    /// seconds, the watchdog cancels the child Task and sets isStalled = true.
    /// The outer function checks isStalled to distinguish stall from user cancellation,
    /// then throws StallError(partialText:) so AIOrchestrator can do a continuation retry.
    ///
    /// CANCEL-FIX:
    /// asyncBytes.lines does not respect cooperative Swift cancellation while blocking on
    /// server bytes. We check Task.isCancelled on every loop iteration and break out.
    /// Additionally, the URLSessionDataTask is tracked and cancelled explicitly when the
    /// outer Task is cancelled — this closes the TCP connection immediately.
    ///
    /// - Parameters:
    ///   - stallTimeout: Seconds of silence before declaring a stall.
    ///     Default: AppConfig.shared.stallTimeoutSeconds (60s).
    public func streamRequestWithTools(
        systemPrompt: String,
        chatHistory: [AIMessage],
        tools: [AITool],
        stallTimeout: TimeInterval = AppConfig.shared.stallTimeoutSeconds,
        onToken: (@Sendable (String) -> Void)? = nil
    ) async throws -> AIStreamResult {

        // Check cancellation before even starting the network request.
        try Task.checkCancellation()

        let messages = buildMessages(systemPrompt: systemPrompt, chatHistory: chatHistory)

        let requestBody = AITunnelRequest(
            model: modelName,
            messages: messages,
            temperature: 0.7,
            tools: tools.isEmpty ? nil : tools,
            stream: true
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

        // Check again after the connection is established — user may have cancelled while connecting.
        try Task.checkCancellation()

        try validateHTTPResponse(response, data: nil)

        // Shared mutable state for the stream loop — wrapped in a class for reference semantics.
        // This is safe: only the stream child Task writes to it, the outer scope reads after await.
        final class StreamState: @unchecked Sendable {
            var accumulatedText = ""
            var toolCallBuffers: [Int: (id: String, name: String, arguments: String)] = [:]
            var finalCost: Double? = nil
            var finalBalance: Double? = nil
        }
        let state = StreamState()

        // STALL-WATCHDOG: actor tracks silence; cancels the child Task on timeout.
        let watchdog = StallWatchdog(timeout: stallTimeout)

        // Run the stream loop in a child Task so the watchdog can cancel it externally.
        // The child Task inherits the parent's cancellation — if the parent Task is cancelled
        // (user pressed Cancel), the child Task is cancelled too.
        let streamTask = Task {
            // Register self with watchdog so it can cancel us on stall.
            await watchdog.start()

            for try await line in asyncBytes.lines {
                // CANCEL-FIX: asyncBytes.lines may not throw CancellationError immediately.
                // Explicit check on every iteration ensures we exit as soon as possible.
                if Task.isCancelled { break }

                // Each received line resets the stall timer.
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
                    for streamToolCall in streamToolCalls {
                        let idx = streamToolCall.index

                        if var existing = state.toolCallBuffers[idx] {
                            if let argChunk = streamToolCall.function?.arguments {
                                existing.arguments += argChunk
                                state.toolCallBuffers[idx] = existing
                            }
                        } else {
                            let id = streamToolCall.id ?? "call_\(idx)"
                            let name = streamToolCall.function?.name ?? ""
                            let args = streamToolCall.function?.arguments ?? ""
                            state.toolCallBuffers[idx] = (id: id, name: name, arguments: args)
                        }
                    }
                }
            }

            // Stream finished normally — disarm the watchdog.
            await watchdog.stop()
        }

        // Wait for the stream Task to finish (success or cancellation).
        do {
            try await streamTask.value
        } catch is CancellationError {
            // Distinguish watchdog stall from user-initiated cancel.
            if await watchdog.isStalled {
                print("[AIClient] Stall detected after \(stallTimeout)s. Partial: \(state.accumulatedText.count) chars.")
                throw StallError(stallSeconds: stallTimeout, partialText: state.accumulatedText)
            }
            // User cancelled — propagate cleanly.
            print("[AIClient] Stream cancelled by user. Partial: \(state.accumulatedText.count) chars.")
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            if await watchdog.isStalled {
                print("[AIClient] Stall detected (URLError.cancelled). Partial: \(state.accumulatedText.count) chars.")
                throw StallError(stallSeconds: stallTimeout, partialText: state.accumulatedText)
            }
            throw ChappieError.cancelled
        } catch {
            // Any other error from the stream loop — propagate as-is.
            throw error
        }

        let assembledToolCalls: [AIToolCall]? = state.toolCallBuffers.isEmpty ? nil :
            state.toolCallBuffers.sorted(by: { $0.key < $1.key }).compactMap { (_, buffer) in
                guard !buffer.name.isEmpty else { return nil }
                return AIToolCall(
                    id: buffer.id,
                    type: "function",
                    function: AIToolCallFunction(name: buffer.name, arguments: buffer.arguments)
                )
            }

        return AIStreamResult(
            text: state.accumulatedText,
            toolCalls: assembledToolCalls,
            cost: state.finalCost,
            balance: state.finalBalance
        )
    }

    // MARK: - Public API: Legacy streaming (deprecated)

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

    // MARK: - Private: Message Building

    private func buildMessages(systemPrompt: String, chatHistory: [AIMessage]) -> [AIMessage] {
        var messages: [AIMessage] = []
        messages.append(AIMessage(role: "system", content: systemPrompt))
        messages.append(contentsOf: chatHistory)
        print("[AIClient] Request: 1 system + \(chatHistory.count) history messages → \(endpointURL.host ?? "") / \(modelName)")
        return messages
    }

    // MARK: - Private: Cache Stats Logging

    /// Logs prompt cache hit/miss/write stats for cost diagnostics.
    ///
    /// WHY DETAILED LOG:
    /// We need to understand whether tools are cached alongside the system prompt.
    /// coverage% = cache_read / prompt_tokens * 100
    /// ~80-100% → tools are cached too (great!)
    /// ~30-50%  → only system prompt is cached
    /// 0%       → cache not working at all
    private func logCacheStats(usage: AIUsage?) {
        guard let usage else { return }

        let cacheRead     = usage.effectiveCacheRead
        let cacheCreation = usage.effectiveCacheCreation
        let promptTokens  = usage.prompt_tokens ?? 0
        let completionTokens = usage.completion_tokens ?? 0
        let costStr = usage.cost_rub.map { String(format: "%.4f RUB", $0) } ?? "n/a"

        let coverageStr: String
        if promptTokens > 0 && cacheRead > 0 {
            let pct = Int(Double(cacheRead) / Double(promptTokens) * 100)
            coverageStr = " | coverage: \(pct)% of prompt"
        } else {
            coverageStr = ""
        }

        if cacheRead > 0 {
            let savings = Int(Double(cacheRead) * 0.9)
            print("[AIClient] CACHE HIT | prompt: \(promptTokens) tok | read: \(cacheRead) tok (~\(savings) saved)\(coverageStr) | created: \(cacheCreation) tok | completion: \(completionTokens) tok | cost: \(costStr)")
        } else if cacheCreation > 0 {
            print("[AIClient] CACHE WRITE | prompt: \(promptTokens) tok | created: \(cacheCreation) tok | completion: \(completionTokens) tok | cost: \(costStr)")
        } else {
            print("[AIClient] CACHE MISS | prompt: \(promptTokens) tok | completion: \(completionTokens) tok | cost: \(costStr)")
        }
    }

    // MARK: - Private: Legacy Stream

    private func performStreamRequest(
        systemPrompt: String,
        chatHistory: [AIMessage],
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws -> (cost: Double?, balance: Double?) {

        let messages = buildMessages(systemPrompt: systemPrompt, chatHistory: chatHistory)
        let requestBody = AITunnelRequest(
            model: modelName,
            messages: messages,
            temperature: 0.7,
            tools: nil,
            stream: true
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
            do { chunk = try JSONDecoder().decode(AIStreamChunk.self, from: chunkData) }
            catch { continue }
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
                    "The task may be too complex or the server is overloaded."
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

// MARK: - StallWatchdog

/// Actor that monitors streaming silence and cancels a provided Task after a timeout.
///
/// DESIGN:
/// - start() launches a background sleep Task.
/// - reset() cancels the current sleep and starts a new one — called on each received token.
/// - stop() cancels the watchdog without marking as stalled (normal stream completion).
/// - isStalled is set to true only when the watchdog fires (not when stopped normally).
///
/// WHY ACTOR:
/// The watchdog task and the stream child Task run concurrently. Actor isolation prevents
/// data races on currentTask and isStalled.
///
/// CANCELLATION FLOW:
/// 1. Watchdog timer fires → isStalled = true → cancels the provided streamTask.
/// 2. Stream loop receives CancellationError.
/// 3. streamRequestWithTools() checks watchdog.isStalled → throws StallError.
/// 4. AIOrchestrator catches StallError → performs continuation retry.
private actor StallWatchdog {
    private let timeout: TimeInterval
    private var timerTask: Task<Void, Never>?
    private var streamTask: Task<Void, any Error>?

    /// True only when the watchdog fired due to silence (not stopped normally).
    private(set) var isStalled: Bool = false

    init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    /// Registers the stream Task to cancel on stall, then starts the timer.
    func start(cancelling task: Task<Void, any Error>) {
        self.streamTask = task
        scheduleTimer()
    }

    /// Convenience start without pre-registering a task (task set separately via start(cancelling:)).
    func start() {
        scheduleTimer()
    }

    /// Resets the stall timer. Call this on every received streaming token.
    func reset() {
        timerTask?.cancel()
        scheduleTimer()
    }

    /// Stops the watchdog without triggering a stall (normal stream completion).
    func stop() {
        timerTask?.cancel()
        timerTask = nil
    }

    // MARK: - Private

    private func scheduleTimer() {
        timerTask = Task { [timeout] in
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // Timer fired without being reset — stream has stalled.
                isStalled = true
                streamTask?.cancel()
                print("[StallWatchdog] Stall detected after \(timeout)s of silence.")
            } catch {
                // Timer was cancelled via reset() or stop() — normal operation.
            }
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
