//
//  AITunnelModels.swift
//  ChappieCore
//
//  Codable/Sendable models for working with the AI provider API (OpenAI-compatible protocol
//  with Anthropic extensions — in particular, Prompt Caching).
//
//  CHANGE (ТД-7 — Streaming):
//  Added `stream` field to AITunnelRequest and new models for SSE chunk parsing.
//
//  CHANGE (ТД-COST — Prompt Caching):
//  Added AIContentBlock and AIMessageContent types for prompt caching support.
//
//  CHANGE (SINGLE-STREAM — Unified streaming cycle):
//  Added AIMessage(role:content:toolCalls:) initializer.
//
//  CHANGE (CACHE-PARSE — AITunnel cache parsing):
//  AITunnel uses non-standard field names for cache stats via prompt_tokens_details.
//
//  CHANGE (TOP-LEVEL-CACHE — Automatic caching via top-level cache_control):
//  Added `cache_control: AICacheControl?` to AITunnelRequest.
//
//  CHANGE (MULTIMODAL — Multimodal content parts):
//  Added AIMultimodalPart struct and .multimodal case to AIMessageContent.
//  Used for user messages that contain image or file attachments.
//  Encodes to OpenAI vision format: array of {type, text} or {type, image_url} objects.

import Foundation

// MARK: - Prompt Caching: Content Blocks

/// Cache control tag — used as a top-level field in AITunnelRequest.
///
/// WHY TOP-LEVEL, NOT PER-BLOCK:
/// AITunnel is an OpenAI-compatible gateway. The `content` field in messages MUST be a string.
/// Passing an array of objects with cache_control inside messages breaks the gateway connection.
/// The correct approach is top-level cache_control in the request body. The gateway moves
/// the breakpoint automatically as the conversation grows (sticky routing).
///
/// WHY TTL 1 HOUR:
/// Chappie development sessions last hours. The default 5-minute TTL means the system prompt
/// (thousands of tokens) is recomputed every 5 minutes of inactivity.
/// With TTL 1h the cache survives breaks and saves up to 90% of system prompt cost.
public struct AICacheControl: Codable, Sendable {
    /// Cache type. Currently only "ephemeral" is supported.
    public let type: String
    /// Cache TTL. "1h" = 1 hour, nil = 5 minutes (default).
    public let ttl: String?

    public init(type: String = "ephemeral", ttl: String? = nil) {
        self.type = type
        self.ttl = ttl
    }

    /// Factory: 1-hour cache — optimal for long development sessions.
    public static let oneHour = AICacheControl(type: "ephemeral", ttl: "1h")

    /// Factory: 5-minute cache (default).
    public static let fiveMinutes = AICacheControl(type: "ephemeral", ttl: nil)
}

/// One content block in a message — text with optional cache tag.
///
/// WHY BLOCKS INSTEAD OF STRING:
/// Standard OpenAI format uses `content: String`. But Anthropic extended the protocol:
/// `content` can be an array of objects `[{type, text, cache_control?}]`.
/// Only through this format can content be marked for caching.
///
/// IMPORTANT: This struct is kept for response decoding compatibility.
/// In requests we do NOT use per-block cache_control — only top-level in AITunnelRequest.
public struct AIContentBlock: Codable, Sendable {
    /// Block type. Always "text" for text blocks.
    public let type: String
    /// Text content of the block.
    public let text: String
    /// Optional cache tag. nil = not cached.
    public let cache_control: AICacheControl?

    public init(text: String, cacheControl: AICacheControl? = nil) {
        self.type = "text"
        self.text = text
        self.cache_control = cacheControl
    }

    /// Factory: cached block.
    public static func cached(_ text: String) -> AIContentBlock {
        AIContentBlock(text: text, cacheControl: AICacheControl())
    }

    /// Factory: plain (non-cached) block.
    public static func plain(_ text: String) -> AIContentBlock {
        AIContentBlock(text: text, cacheControl: nil)
    }
}

// MARK: - Multimodal Content Parts

/// One part of a multimodal message — either plain text or an image (via data URI).
///
/// WHY THIS TYPE:
/// OpenAI vision API requires `content` to be an array of typed parts when sending images:
///   [
///     { "type": "text", "text": "What's in this image?" },
///     { "type": "image_url", "image_url": { "url": "data:image/jpeg;base64,..." } }
///   ]
///
/// For non-image files (PDF, TXT) we inline their content as a text part with a header,
/// since most models cannot process binary formats directly — but can read extracted text.
///
/// DESIGN DECISION — send everything, handle errors gracefully:
/// We do not filter by model capability. If the model rejects the content type,
/// the API returns an error which ChappieViewModel surfaces as a human-friendly message.
public enum AIMultimodalPart: Encodable, Sendable {

    /// Plain text part — the user's typed prompt.
    case text(String)

    /// Image part — base64 data URI. Used for image/jpeg, image/png, image/gif, image/webp.
    case imageURL(String)

    // MARK: - Encodable

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
            let imageURLObj = ImageURLObject(url: url)
            try container.encode(imageURLObj, forKey: .imageURL)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }

    // Nested struct for the image_url object
    private struct ImageURLObject: Encodable {
        let url: String
    }
}

// MARK: - AIMessageContent

/// Polymorphic message content: plain string, array of cached blocks, or multimodal parts.
///
/// WHY ENUM:
/// API accepts all formats. For plain text messages we use .text — compact and compatible.
/// For messages with image/file attachments we use .multimodal — encodes to vision array.
/// .blocks is kept for response decoding that may arrive in extended Anthropic format.
public enum AIMessageContent: Sendable {
    /// Plain string — for all non-multimodal messages.
    case text(String)
    /// Array of content blocks — for decoding responses in extended Anthropic format.
    case blocks([AIContentBlock])
    /// Array of typed parts — for user messages with image/file attachments (OpenAI vision).
    case multimodal([AIMultimodalPart])
}

extension AIMessageContent: Encodable {
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let string):
            // Encode as plain string — standard OpenAI format, compatible with AITunnel
            var container = encoder.singleValueContainer()
            try container.encode(string)
        case .blocks(let blocks):
            // Encode as array of objects — extended Anthropic format.
            // WARNING: do NOT use in requests to AITunnel — gateway rejects arrays.
            var container = encoder.singleValueContainer()
            try container.encode(blocks)
        case .multimodal(let parts):
            // Encode as array of typed parts — OpenAI vision format.
            // Used when the user message contains image or file attachments.
            var container = encoder.singleValueContainer()
            try container.encode(parts)
        }
    }
}

extension AIMessageContent: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Try string first (most common case in API responses)
        if let string = try? container.decode(String.self) {
            self = .text(string)
        } else if let blocks = try? container.decode([AIContentBlock].self) {
            self = .blocks(blocks)
        } else {
            // Neither — treat as empty string, don't crash
            self = .text("")
        }
    }
}

// MARK: - Request Models

/// POST request body for the AI provider API.
///
/// FIELD cache_control (TOP-LEVEL CACHING):
/// Key field for automatic prompt caching via AITunnel.
/// Placed at the top level of the request (alongside model, messages) — this is NOT
/// the same as per-block cache_control inside messages.
///
/// FIELD stream:
/// - `stream = false` (default) → standard blocking response
/// - `stream = true`  → server returns a stream of `data: {...}\n\n` chunks
public struct AITunnelRequest: Encodable, Sendable {
    public let model: String
    public let messages: [AIMessage]
    public let temperature: Double?
    public let tools: [AITool]?
    /// Enables SSE streaming (Server-Sent Events).
    public let stream: Bool
    /// Top-level cache control for automatic prompt caching.
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

/// A single message in the conversation (role + content + optional fields).
///
/// FIELD `content` is `AIMessageContent?` — polymorphic:
///   .text(String)                — plain text, used for all standard messages
///   .blocks([AIContentBlock])    — Anthropic extended format, kept for decoding
///   .multimodal([AIMultimodalPart]) — OpenAI vision format, used for messages with attachments
///
/// `contentString` computed property provides backward-compatible string access.
public struct AIMessage: Codable, Sendable {
    public var role: String
    public var content: AIMessageContent?
    public var tool_calls: [AIToolCall]?
    public var tool_call_id: String?
    public var name: String?

    /// Convenient string access — no manual enum unwrapping needed.
    public var contentString: String? {
        guard let content else { return nil }
        switch content {
        case .text(let s): return s
        case .blocks(let blocks): return blocks.map(\.text).joined()
        case .multimodal: return nil  // Multimodal has no single string representation
        }
    }

    /// Standard string initializer — backward compatible with all existing code.
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

    /// Blocks initializer — kept for compatibility, NOT for use in AITunnel requests.
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

    /// Multimodal initializer — for user messages with image/file attachments.
    ///
    /// MULTIMODAL: Creates a message with .multimodal content that encodes to
    /// OpenAI vision array format. Used by buildRawNetworkHistory() when the
    /// user message has attachments.
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

    /// Streaming assistant message initializer — for creating messages from streaming buffer.
    ///
    /// WHY SEPARATE: In the unified streaming cycle (no probe request), AIOrchestrator
    /// accumulates the response in a text buffer and creates an AIMessage after the stream ends.
    /// This initializer makes that creation explicit and semantically clear.
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

/// Full API response for a non-streaming request.
public struct AITunnelResponse: Decodable, Sendable {
    public let id: String?
    public let choices: [AIChoice]
    public let usage: AIUsage?
}

/// One response choice (usually choices[0]).
public struct AIChoice: Decodable, Sendable {
    public let message: AIMessage
    public let finish_reason: String?
}

// MARK: - Cache Statistics

/// Prompt token breakdown — nested object `prompt_tokens_details`.
///
/// WHY SEPARATE STRUCT:
/// AITunnel returns cache stats NOT at the top level of usage (like standard Anthropic),
/// but as a nested object prompt_tokens_details. This is a non-standard provider extension.
public struct AIPromptTokensDetails: Decodable, Sendable {
    /// Tokens written to cache in this request (AITunnel-specific field).
    public let cache_write_tokens: Int?
    /// Tokens read from cache (AITunnel-specific field).
    public let cached_tokens: Int?
    public let audio_tokens: Int?
    public let video_tokens: Int?
}

/// Token usage statistics and financial information.
public struct AIUsage: Decodable, Sendable {
    public let prompt_tokens: Int?
    public let completion_tokens: Int?
    public let total_tokens: Int?
    public let cost_rub: Double?
    public let balance: Double?

    /// Standard Anthropic fields (may be absent for AITunnel).
    public let cache_creation_input_tokens: Int?
    public let cache_read_input_tokens: Int?

    /// Non-standard AITunnel cache breakdown object.
    public let prompt_tokens_details: AIPromptTokensDetails?

    // MARK: - Computed properties for unified interface

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
/// Server sends a stream of lines like:
///   data: {"id":"...","choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}\n\n
///   data: [DONE]\n\n
///
/// Each such line (except [DONE]) decodes into AIStreamChunk.
/// The `usage` field is present only in the last chunk before [DONE].
public struct AIStreamChunk: Decodable, Sendable {
    public let id: String?
    public let choices: [AIStreamChoice]
    /// Token stats — present only in the final chunk.
    public let usage: AIUsage?
}

/// One response choice inside an SSE chunk.
public struct AIStreamChoice: Decodable, Sendable {
    /// Delta update: new tokens or start of a tool_call.
    public let delta: AIStreamDelta
    /// "stop" = end of generation, nil = continues.
    public let finish_reason: String?
}

/// Delta update: text increment or tool call.
///
/// WHY TWO OPTIONAL FIELDS:
/// The model generates either text (`content`) or a tool call (`tool_calls`), never both
/// simultaneously. The first tool_call chunk contains id and name; subsequent chunks
/// contain only `arguments` (JSON accumulates gradually).
public struct AIStreamDelta: Decodable, Sendable {
    /// New text tokens (nil if this is a tool_call chunk).
    public let content: String?
    /// Tool calls — arrive in parts, must be accumulated.
    public let tool_calls: [AIStreamToolCall]?
}

/// Partial tool call from SSE stream.
///
/// Unlike AIToolCall (complete, from non-streaming response), this arrives in pieces:
///   - First chunk: id="call_abc", function.name="write_file", function.arguments="{"
///   - Subsequent: id=nil, function.name=nil, function.arguments="path"
/// Therefore index is required — used to accumulate arguments into the correct slot.
public struct AIStreamToolCall: Decodable, Sendable {
    /// Sequential number of the tool_call (for parallel calls).
    public let index: Int
    /// Call ID — present only in the first chunk of this tool_call.
    public let id: String?
    /// Type — usually "function", present only in the first chunk.
    public let type: String?
    /// Partial function data.
    public let function: AIStreamToolCallFunction?
}

/// Partial function data from SSE stream.
public struct AIStreamToolCallFunction: Decodable, Sendable {
    /// Function name — only in the first chunk.
    public let name: String?
    /// Piece of JSON arguments — accumulates across chunks.
    public let arguments: String?
}

// MARK: - Streaming Result

/// Complete result of a streaming request with tool call support.
///
/// WHY SEPARATE STRUCT:
/// streamRequestWithTools() must return not just the token stream,
/// but also the assembled tool_calls (which arrive in pieces in deltas).
/// This struct aggregates everything accumulated during the stream.
public struct AIStreamResult: Sendable {
    /// Accumulated text response (empty if only tool_calls were returned).
    public let text: String
    /// Assembled tool calls (nil if only text was returned).
    public let toolCalls: [AIToolCall]?
    /// Request cost in rubles.
    public let cost: Double?
    /// Updated balance after the request.
    public let balance: Double?
}
