// AnthropicClient.swift
// ChappieCore
//
// Native Anthropic API client — implements AIClientProtocol.
//
// WIRE FORMAT DIFFERENCES vs OpenAI:
// - Endpoint: POST /v1/messages (not /v1/chat/completions)
// - System prompt: top-level "system" field (not a message with role "system")
// - Tool results: role "user" with content array of type "tool_result"
// - Tool calls: content array blocks of type "tool_use" (not delta.tool_calls)
// - Streaming: event: content_block_delta / event: message_delta (not data: {...})
// - Default auth: x-api-key header + anthropic-version header
// - max_tokens is REQUIRED (no default)
// - No /v1/models endpoint — fetchAvailableModels() returns []
//
// AUTH SCHEME:
// By default uses x-api-key (native Anthropic). Can be overridden to Bearer
// for proxy providers (e.g. AITunnel routing to Claude via /v1/messages).
// .none — no auth header (unusual for Anthropic, but supported for custom setups).
//
// TOOL CALL STREAMING:
// Anthropic streams tool calls as content_block_start (type=tool_use, id, name)
// followed by content_block_delta (input_json_delta with partial JSON).
// We accumulate them by content block index, same logic as OpenAI.
//
// BALANCE / COST:
// Native Anthropic does not return balance or cost_rub — those are AITunnel extensions.
// AnthropicUsage decodes them as optional so proxy providers (AITunnel /v1/messages)
// can return billing info through the same client.

import Foundation

// MARK: - AnthropicClient

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
        // Anthropic has no /models endpoint — send a minimal messages request
        // with max_tokens=1 to confirm auth works.
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

    /// Anthropic has no public /models endpoint — returns empty array.
    public func fetchAvailableModels() async -> [String] { [] }

    // MARK: - AIClientProtocol: sendRequest (non-streaming)

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
                        state.toolBlocks[idx] = (
                            id: block.id ?? "call_\(idx)",
                            name: block.name ?? "",
                            inputJSON: ""
                        )
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
                            if let partial = delta.partialJSON {
                                if var existing = state.toolBlocks[idx] {
                                    existing.inputJSON += partial
                                    state.toolBlocks[idx] = existing
                                }
                            }
                        default: break
                        }
                    }

                case "message_delta":
                    if let usage = json.usage {
                        // Capture billing info — available from proxy providers like AITunnel.
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

    /// Merges consecutive same-role messages.
    /// Anthropic rejects requests where two consecutive messages have the same role.
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

        // Apply auth scheme — x-api-key for native Anthropic, Bearer for proxies, none for open endpoints.
        switch authScheme {
        case .xApiKey:
            request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        case .bearer:
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .none:
            break // no auth header
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

    // MARK: - Private: Cache Stats

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

// MARK: - Anthropic Request Models

private struct AnthropicRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String?
    let messages: [AnthropicMessage]
    let tools: [AnthropicTool]?
    let stream: Bool

    private enum CodingKeys: String, CodingKey {
        case model, system, messages, tools, stream
        case maxTokens = "max_tokens"
    }
}

// MARK: - AnthropicMessage

private struct AnthropicMessage: Encodable {
    let role: String
    let content: AnthropicMessageContent

    var contentString: String? {
        switch content {
        case .text(let t): return t
        case .blocks(let blocks): return blocks.compactMap { $0.text }.joined(separator: "\n")
        case .toolResult(let r): return r.content
        }
    }
}

private enum AnthropicMessageContent: Encodable {
    case text(String)
    case blocks([AnthropicContentBlock])
    case toolResult(AnthropicToolResultContent)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let t):
            var c = encoder.singleValueContainer()
            try c.encode(t)
        case .blocks(let blocks):
            var c = encoder.singleValueContainer()
            try c.encode(blocks)
        case .toolResult(let r):
            var c = encoder.singleValueContainer()
            try c.encode([r])
        }
    }
}

private struct AnthropicContentBlock: Encodable {
    let type: String
    var text: String? = nil
    var id: String? = nil
    var name: String? = nil
    var input: [String: Any]? = nil
    var source: AnthropicImageSource? = nil

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        if let text { try container.encode(text, forKey: .text) }
        if let id { try container.encode(id, forKey: .id) }
        if let name { try container.encode(name, forKey: .name) }
        if let source { try container.encode(source, forKey: .source) }
        if let input {
            let jsonData = try JSONSerialization.data(withJSONObject: input)
            let jsonValue = try JSONDecoder().decode(JSONValue.self, from: jsonData)
            try container.encode(jsonValue, forKey: .input)
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, text, id, name, input, source
    }
}

private struct AnthropicImageSource: Encodable {
    let type: String
    let mediaType: String
    let data: String

    enum CodingKeys: String, CodingKey {
        case type, data
        case mediaType = "media_type"
    }
}

private struct AnthropicToolResultContent: Encodable {
    let type: String
    let toolUseId: String
    let content: String

    enum CodingKeys: String, CodingKey {
        case type, content
        case toolUseId = "tool_use_id"
    }
}

// MARK: - Anthropic Tool Models

private struct AnthropicTool: Encodable {
    let name: String
    let description: String
    let inputSchema: AnthropicToolInputSchema

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }
}

private struct AnthropicToolInputSchema: Encodable {
    let type: String
    let properties: [String: AnthropicToolProperty]
    let required: [String]?
}

private struct AnthropicToolProperty: Encodable {
    let type: String
    let description: String?
}

// MARK: - Anthropic Streaming Event Models

private struct AnthropicStreamEvent: Decodable {
    let type: String
    let index: Int?
    let delta: AnthropicDelta?
    let contentBlock: AnthropicContentBlockInfo?
    let usage: AnthropicUsage?

    enum CodingKeys: String, CodingKey {
        case type, index, delta, usage
        case contentBlock = "content_block"
    }
}

private struct AnthropicDelta: Decodable {
    let type: String
    let text: String?
    let partialJSON: String?

    enum CodingKeys: String, CodingKey {
        case type, text
        case partialJSON = "partial_json"
    }
}

private struct AnthropicContentBlockInfo: Decodable {
    let type: String
    let id: String?
    let name: String?
}

/// Token usage and optional billing info from Anthropic / proxy responses.
///
/// Native Anthropic does not include costRub / balance — those are AITunnel extensions.
/// Declared as optional so the same struct works for both native and proxy providers.
private struct AnthropicUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?
    /// AITunnel extension — cost of this request in RUB.
    let costRub: Double?
    /// AITunnel extension — remaining balance in RUB after the request.
    let balance: Double?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case costRub = "cost_rub"
        case balance
    }
}

// MARK: - JSONValue (for encoding arbitrary [String: Any])

private enum JSONValue: Encodable, Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Int.self) { self = .int(v); return }
        if let v = try? container.decode(Double.self) { self = .double(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        if let v = try? container.decode([String: JSONValue].self) { self = .object(v); return }
        if let v = try? container.decode([JSONValue].self) { self = .array(v); return }
        self = .null
    }
}
