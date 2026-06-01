import Foundation

// MARK: - Prompt Caching: Content Blocks

/// Cache control tag — placed at the top level of AITunnelRequest, not per-block.
///
/// WHY TOP-LEVEL: AITunnel is an OpenAI-compatible gateway; passing cache_control inside
/// message content arrays breaks the connection. Top-level placement lets the gateway
/// move the breakpoint automatically as the conversation grows.
///
/// WHY 1H TTL: Default 5-min TTL means the system prompt is recomputed every break.
/// 1h covers full dev sessions and saves ~80-90% of system prompt cost.
public struct AICacheControl: Codable, Sendable {
    public let type: String
    /// "1h" = 1 hour, nil = 5 minutes (provider default).
    public let ttl: String?

    public init(type: String = "ephemeral", ttl: String? = nil) {
        self.type = type
        self.ttl = ttl
    }

    public static let oneHour = AICacheControl(type: "ephemeral", ttl: "1h")
    public static let fiveMinutes = AICacheControl(type: "ephemeral", ttl: nil)
}

/// One content block — text with optional cache tag.
///
/// Kept for response decoding compatibility. In requests we use top-level cache_control
/// on AITunnelRequest instead — per-block cache_control is NOT sent to AITunnel.
public struct AIContentBlock: Codable, Sendable {
    public let type: String
    public let text: String
    public let cache_control: AICacheControl?

    public init(text: String, cacheControl: AICacheControl? = nil) {
        self.type = "text"
        self.text = text
        self.cache_control = cacheControl
    }

    public static func cached(_ text: String) -> AIContentBlock {
        AIContentBlock(text: text, cacheControl: AICacheControl())
    }

    public static func plain(_ text: String) -> AIContentBlock {
        AIContentBlock(text: text, cacheControl: nil)
    }
}

// MARK: - Multimodal Content Parts

/// One part of a multimodal message — plain text or an image (data URI).
///
/// WHY: OpenAI vision API requires content to be an array of typed parts when sending images.
/// For non-image files (PDF, TXT) we inline extracted text as a text part — most models
/// can't process binary formats directly.
///
/// We don't filter by model capability — if the model rejects the type, the API returns
/// an error which ChappieViewModel surfaces as a human-friendly message.
public enum AIMultimodalPart: Encodable, Sendable {

    case text(String)
    /// Base64 data URI. Used for image/jpeg, image/png, image/gif, image/webp.
    case imageURL(String)

    // Encodes to OpenAI vision format:
    // text  → { "type": "text",      "text": "..." }
    // image → { "type": "image_url", "image_url": { "url": "data:..." } }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let content):
            try container.encode("text", forKey: .type)
            try container.encode(content, forKey: .text)
        case .imageURL(let url):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageURLObject(url: url), forKey: .imageURL)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }

    private struct ImageURLObject: Encodable {
        let url: String
    }
}

// MARK: - AIMessageContent

/// Polymorphic message content: plain string, cached blocks, or multimodal parts.
///
/// .text — all non-multimodal messages (standard OpenAI format).
/// .blocks — decoding only; NOT sent to AITunnel (gateway rejects arrays).
/// .multimodal — user messages with image/file attachments (OpenAI vision format).
public enum AIMessageContent: Sendable {
    case text(String)
    case blocks([AIContentBlock])
    case multimodal([AIMultimodalPart])
}

extension AIMessageContent: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let string):
            try container.encode(string)
        case .blocks(let blocks):
            // WARNING: do NOT use in AITunnel requests — gateway rejects arrays.
            try container.encode(blocks)
        case .multimodal(let parts):
            try container.encode(parts)
        }
    }
}

extension AIMessageContent: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .text(string)
        } else if let blocks = try? container.decode([AIContentBlock].self) {
            self = .blocks(blocks)
        } else {
            self = .text("")
        }
    }
}

// MARK: - Request Models

/// POST request body for the AI provider API.
///
/// cache_control is top-level (not per-block) — required by AITunnel gateway.
/// stream=true → SSE chunks; stream=false → single blocking response.
public struct AITunnelRequest: Encodable, Sendable {
    public let model: String
    public let messages: [AIMessage]
    public let temperature: Double?
    public let tools: [AITool]?
    public let stream: Bool
    public let cache_control: AICacheControl?

    public init(
        model: String,
        messages: [AIMessage],
        temperature: Double? = nil,
        tools: [AITool]? = nil,
        stream: Bool = false,
        cacheControl: AICacheControl? = .oneHour
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.tools = tools
        self.stream = stream
        self.cache_control = cacheControl
    }
}

/// A single message in the conversation.
///
/// content is AIMessageContent? — polymorphic (.text / .blocks / .multimodal).
/// contentString provides backward-compatible string access without manual unwrapping.
public struct AIMessage: Codable, Sendable {
    public var role: String
    public var content: AIMessageContent?
    public var tool_calls: [AIToolCall]?
    public var tool_call_id: String?
    public var name: String?

    public var contentString: String? {
        guard let content else { return nil }
        switch content {
        case .text(let s): return s
        case .blocks(let blocks): return blocks.map(\.text).joined()
        case .multimodal: return nil
        }
    }

    public init(
        role: String,
        content: String? = nil,
        tool_calls: [AIToolCall]? = nil,
        tool_call_id: String? = nil,
        name: String? = nil
    ) {
        self.role = role
        self.content = content.map { .text($0) }
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
        self.name = name
    }

    /// Blocks initializer — kept for compatibility. NOT for AITunnel requests.
    public init(
        role: String,
        contentBlocks: [AIContentBlock],
        tool_calls: [AIToolCall]? = nil,
        tool_call_id: String? = nil,
        name: String? = nil
    ) {
        self.role = role
        self.content = .blocks(contentBlocks)
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
        self.name = name
    }

    /// Multimodal initializer — encodes to OpenAI vision array format.
    public init(
        role: String,
        multimodalParts: [AIMultimodalPart],
        tool_calls: [AIToolCall]? = nil,
        tool_call_id: String? = nil,
        name: String? = nil
    ) {
        self.role = role
        self.content = .multimodal(multimodalParts)
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
        self.name = name
    }

    /// Streaming assistant message initializer — creates a message from the accumulated stream buffer.
    public init(
        role: String,
        content: String?,
        toolCalls: [AIToolCall]?,
        tool_call_id: String? = nil,
        name: String? = nil
    ) {
        self.role = role
        self.content = content.map { .text($0) }
        self.tool_calls = toolCalls
        self.tool_call_id = tool_call_id
        self.name = name
    }
}

// MARK: - Functions and Schemas (Function Calling)

public struct AITool: Codable, Sendable {
    public let type: String
    public let function: AIFunctionDefinition

    public init(type: String = "function", function: AIFunctionDefinition) {
        self.type = type
        self.function = function
    }
}

public struct AIFunctionDefinition: Codable, Sendable {
    public let name: String
    public let description: String
    public let parameters: AIToolParameters

    public init(name: String, description: String, parameters: AIToolParameters) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct AIToolParameters: Codable, Sendable {
    public var type: String = "object"
    public let properties: [String: AIToolProperty]
    public let required: [String]?

    public init(type: String = "object", properties: [String: AIToolProperty], required: [String]? = nil) {
        self.type = type
        self.properties = properties
        self.required = required
    }
}

public struct AIToolProperty: Codable, Sendable {
    public let type: String
    public let description: String?

    public init(type: String, description: String?) {
        self.type = type
        self.description = description
    }
}

// MARK: - Response Models (Non-Streaming)

public struct AITunnelResponse: Decodable, Sendable {
    public let id: String?
    public let choices: [AIChoice]
    public let usage: AIUsage?
}

public struct AIChoice: Decodable, Sendable {
    public let message: AIMessage
    public let finish_reason: String?
}

// MARK: - Cache Statistics

/// Token breakdown from prompt_tokens_details (AITunnel-specific nested object).
///
/// WHY SEPARATE: AITunnel returns cache stats inside prompt_tokens_details,
/// not at the top level like standard Anthropic. This struct decodes that nested object.
public struct AIPromptTokensDetails: Decodable, Sendable {
    public let cache_write_tokens: Int?
    public let cached_tokens: Int?
    public let audio_tokens: Int?
    public let video_tokens: Int?
}

/// Token usage and financial stats from the API response.
public struct AIUsage: Decodable, Sendable {
    public let prompt_tokens: Int?
    public let completion_tokens: Int?
    public let total_tokens: Int?
    public let cost_rub: Double?
    public let balance: Double?

    public let cache_creation_input_tokens: Int?
    public let cache_read_input_tokens: Int?
    /// AITunnel-specific cache breakdown (non-standard nested object).
    public let prompt_tokens_details: AIPromptTokensDetails?

    /// Tokens written to cache — works with both Anthropic and AITunnel formats.
    public var effectiveCacheCreation: Int {
        if let standard = cache_creation_input_tokens, standard > 0 { return standard }
        return prompt_tokens_details?.cache_write_tokens ?? 0
    }

    /// Tokens read from cache — works with both Anthropic and AITunnel formats.
    public var effectiveCacheRead: Int {
        if let standard = cache_read_input_tokens, standard > 0 { return standard }
        return prompt_tokens_details?.cached_tokens ?? 0
    }
}

// MARK: - Tool Call Models

public struct AIToolCall: Codable, Sendable {
    public var id: String
    public var type: String
    public var function: AIToolCallFunction

    public init(id: String, type: String, function: AIToolCallFunction) {
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct AIToolCallFunction: Codable, Sendable {
    public var name: String
    public var arguments: String

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}

// MARK: - Streaming Models (SSE)

/// One SSE stream chunk.
///
/// Server sends lines like: data: {"choices":[{"delta":{"content":"Hi"}}]}\n\n
/// Each line (except [DONE]) decodes into AIStreamChunk.
/// usage is present only in the final chunk before [DONE].
public struct AIStreamChunk: Decodable, Sendable {
    public let id: String?
    public let choices: [AIStreamChoice]
    public let usage: AIUsage?
}

public struct AIStreamChoice: Decodable, Sendable {
    public let delta: AIStreamDelta
    /// "stop" = generation complete, nil = still streaming.
    public let finish_reason: String?
}

/// Delta update: text increment or tool call fragment.
///
/// content and tool_calls are mutually exclusive — the model generates one or the other,
/// never both in the same chunk.
public struct AIStreamDelta: Decodable, Sendable {
    public let content: String?
    /// Tool calls arrive in fragments and must be accumulated by index.
    public let tool_calls: [AIStreamToolCall]?
}

/// Partial tool call from SSE stream.
///
/// Arrives in pieces: first chunk has id + name, subsequent chunks have only arguments.
/// index is used to accumulate fragments into the correct slot for parallel calls.
public struct AIStreamToolCall: Decodable, Sendable {
    public let index: Int
    public let id: String?
    public let type: String?
    public let function: AIStreamToolCallFunction?
}

public struct AIStreamToolCallFunction: Decodable, Sendable {
    /// Present only in the first chunk for this tool call.
    public let name: String?
    /// Accumulates across chunks — each chunk appends a JSON fragment.
    public let arguments: String?
}

// MARK: - Streaming Result

/// Complete result of a streaming request.
///
/// streamRequestWithTools() returns both the assembled text and tool_calls
/// (which arrive as fragments in SSE deltas and must be accumulated).
public struct AIStreamResult: Sendable {
    public let text: String
    public let toolCalls: [AIToolCall]?
    public let cost: Double?
    public let balance: Double?
}
