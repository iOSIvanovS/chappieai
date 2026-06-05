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

    private let endpointURL: URL
    private let apiKey: String
    private let modelName: String
    private let authScheme: AuthScheme
    private let urlSession: URLSession

    private static let anthropicVersion = "2023-06-01"
    private static let maxTokens = 8192

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

    // MARK: - AIClientProtocol: streamRequestWithTools

    public func streamRequestWithTools(
        systemPrompt: String,
        chatHistory: [AIMessage],
        tools: [AITool],
        stallTimeout: TimeInterval = AppConfig.shared.stallTimeoutSeconds,
        onToken: (@Sendable (String) -> Void)? = nil
    ) async throws -> AIStreamResult {

        try Task.checkCancellation()

        let anthropicMessages = buildAnthropicMessages(from: chatHistory)
        let anthropicTools = tools.isEmpty ? nil : tools.map(convertTool)

        let body = AnthropicRequest(
            model: modelName,
            maxTokens: Self.maxTokens,
            system: systemPrompt.isEmpty ? nil : systemPrompt,
            messages: anthropicMessages,
            tools: anthropicTools,
            stream: true
        )

        print("[AnthropicClient] Request: \(anthropicMessages.count) messages → \(endpointURL.host ?? "") / \(modelName)")

        let request = try buildRequest(body: body)

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
            var toolBlocks: [Int: (id: String, name: String, inputJSON: String)] = [:]
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

                if line.hasPrefix("event: ") { continue }
                guard line.hasPrefix("data: ") else { continue }
                let jsonString = String(line.dropFirst(6))
                guard !jsonString.isEmpty else { continue }

                guard let data = jsonString.data(using: .utf8),
                      let json = try? JSONDecoder().decode(AnthropicStreamEvent.self, from: data) else {
                    continue
                }

                switch json.type {
                case "content_block_start":
                    if let block = json.contentBlock, block.type == "tool_use" {
                        let idx = json.index ?? 0
                        state.toolBlocks[idx] = (id: block.id ?? "call_\(idx)", name: block.name ?? "", inputJSON: "")
                    }

                case "content_block_delta":
                    let idx = json.index ?? 0
                    if let delta = json.delta {
                        switch delta.type {
                        case "text_delta":
                            if let text = delta.text, !text.isEmpty {
                                state.accumulatedText += text
                                onToken?(text)
                            }
                        case "input_json_delta":
                            if let partial = delta.partialJSON, var existing = state.toolBlocks[idx] {
                                existing.inputJSON += partial
                                state.toolBlocks[idx] = existing
                            }
                        default: break
                        }
                    }

                case "message_delta":
                    if let usage = json.usage {
                        state.finalCost = usage.costRub
                        state.finalBalance = usage.balance
                        logCacheStats(
                            inputTokens: usage.inputTokens ?? 0,
                            outputTokens: usage.outputTokens ?? 0,
                            cacheRead: usage.cacheReadInputTokens ?? 0,
                            cacheCreation: usage.cacheCreationInputTokens ?? 0,
                            cost: usage.costRub,
                            balance: usage.balance
                        )
                    }

                default: break
                }
            }

            await watchdog.stop()
        }

        do {
            try await streamTask.value
        } catch is CancellationError {
            if await watchdog.isStalled {
                throw StallError(stallSeconds: stallTimeout, partialText: state.accumulatedText)
            }
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            if await watchdog.isStalled {
                throw StallError(stallSeconds: stallTimeout, partialText: state.accumulatedText)
            }
            throw ChappieError.cancelled
        } catch {
            throw error
        }

        let toolCalls: [AIToolCall]? = state.toolBlocks.isEmpty ? nil :
            state.toolBlocks.sorted(by: { $0.key < $1.key }).compactMap { (_, block) in
                guard !block.name.isEmpty else { return nil }
                return AIToolCall(
                    id: block.id,
                    type: "function",
                    function: AIToolCallFunction(name: block.name, arguments: block.inputJSON)
                )
            }

        return AIStreamResult(
            text: state.accumulatedText,
            toolCalls: toolCalls,
            cost: state.finalCost,
            balance: state.finalBalance
        )
    }

    // MARK: - Private: Message Conversion

    private func buildAnthropicMessages(from history: [AIMessage]) -> [AnthropicMessage] {
        var result: [AnthropicMessage] = []

        for msg in history {
            switch msg.role {
            case "system":
                continue

            case "tool":
                let toolResult = AnthropicToolResultContent(
                    type: "tool_result",
                    toolUseId: msg.tool_call_id ?? "",
                    content: msg.contentString ?? ""
                )
                result.append(AnthropicMessage(role: "user", content: .toolResult(toolResult)))

            case "assistant":
                if let toolCalls = msg.tool_calls, !toolCalls.isEmpty {
                    var blocks: [AnthropicContentBlock] = []
                    if let text = msg.contentString, !text.isEmpty {
                        blocks.append(AnthropicContentBlock(type: "text", text: text))
                    }
                    for call in toolCalls {
                        let inputData = call.function.arguments.data(using: .utf8) ?? Data()
                        let inputJSON = (try? JSONSerialization.jsonObject(with: inputData)) ?? [String: Any]()
                        blocks.append(AnthropicContentBlock(
                            type: "tool_use",
                            id: call.id,
                            name: call.function.name,
                            input: inputJSON as? [String: Any]
                        ))
                    }
                    result.append(AnthropicMessage(role: "assistant", content: .blocks(blocks)))
                } else {
                    result.append(AnthropicMessage(role: "assistant", content: .text(msg.contentString ?? "")))
                }

            default:
                switch msg.content {
                case .multimodal(let parts):
                    let blocks = parts.compactMap { part -> AnthropicContentBlock? in
                        switch part {
                        case .text(let t):
                            return AnthropicContentBlock(type: "text", text: t)
                        case .imageURL(let url):
                            guard url.hasPrefix("data:") else { return nil }
                            let withoutData = String(url.dropFirst(5))
                            guard let semicolon = withoutData.firstIndex(of: ";"),
                                  let comma = withoutData.firstIndex(of: ",") else { return nil }
                            let mediaType = String(withoutData[withoutData.startIndex..<semicolon])
                            let base64Data = String(withoutData[withoutData.index(after: comma)...])
                            return AnthropicContentBlock(
                                type: "image",
                                source: AnthropicImageSource(type: "base64", mediaType: mediaType, data: base64Data)
                            )
                        }
                    }
                    result.append(AnthropicMessage(role: "user", content: .blocks(blocks)))
                default:
                    result.append(AnthropicMessage(role: "user", content: .text(msg.contentString ?? "")))
                }
            }
        }

        return mergeConsecutiveSameRole(result)
    }

    /// Anthropic rejects requests where two consecutive messages share the same role.
    private func mergeConsecutiveSameRole(_ messages: [AnthropicMessage]) -> [AnthropicMessage] {
        var merged: [AnthropicMessage] = []
        for msg in messages {
            if let last = merged.last, last.role == msg.role {
                let combined = [last.contentString ?? "", msg.contentString ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: "\n\n")
                merged[merged.count - 1] = AnthropicMessage(role: last.role, content: .text(combined))
            } else {
                merged.append(msg)
            }
        }
        return merged
    }

    // MARK: - Private: Tool Conversion

    private func convertTool(_ tool: AITool) -> AnthropicTool {
        let props = tool.function.parameters.properties.mapValues { prop in
            AnthropicToolProperty(type: prop.type, description: prop.description)
        }
        return AnthropicTool(
            name: tool.function.name,
            description: tool.function.description,
            inputSchema: AnthropicToolInputSchema(
                type: "object",
                properties: props,
                required: tool.function.parameters.required
            )
        )
    }

    // MARK: - Private: HTTP Helpers

    private func buildRequest(body: AnthropicRequest) throws -> URLRequest {
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

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
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

    private func validateHTTPResponse(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ChappieError.networkError("Invalid response type")
        }
        guard !(200...299).contains(http.statusCode) else { return }
        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if http.statusCode == 413 || body.lowercased().contains("context") {
            throw ChappieError.aiContextLimitExceeded
        }
        throw ChappieError.networkError("HTTP \(http.statusCode): \(body)")
    }

    // MARK: - Private: Cache Stats Logging

    private func logCacheStats(
        inputTokens: Int,
        outputTokens: Int,
        cacheRead: Int,
        cacheCreation: Int,
        cost: Double?,
        balance: Double?
    ) {
        let costStr = cost.map { String(format: "%.4f RUB", $0) } ?? "n/a"
        let balanceStr = balance.map { String(format: "%.2f RUB", $0) } ?? "n/a"

        if cacheRead > 0 {
            let pct = inputTokens > 0 ? Int(Double(cacheRead) / Double(inputTokens) * 100) : 0
            print("[AnthropicClient] CACHE HIT | input: \(inputTokens) | read: \(cacheRead) (\(pct)%) | created: \(cacheCreation) | output: \(outputTokens) | cost: \(costStr) | balance: \(balanceStr)")
        } else if cacheCreation > 0 {
            print("[AnthropicClient] CACHE WRITE | input: \(inputTokens) | created: \(cacheCreation) | output: \(outputTokens) | cost: \(costStr) | balance: \(balanceStr)")
        } else {
            print("[AnthropicClient] CACHE MISS | input: \(inputTokens) | output: \(outputTokens) | cost: \(costStr) | balance: \(balanceStr)")
        }
    }
}
