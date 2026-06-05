import Foundation

// MARK: - Multimodal Content Parts

/// One part of a multimodal message — plain text or an image (data URI).
///
/// WHY: OpenAI vision API requires content to be an array of typed parts when sending images.
/// For non-image files (PDF, TXT) we inline extracted text as a text part — most models
/// can't process binary formats directly.
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
/// .text      — standard messages for all providers.
/// .blocks    — content block array with optional cache_control. Used for system message
///              caching on AITunnel (supportsCaching=true). Not sent to strict providers.
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
            // Sent as content array — supported by AITunnel for system message caching.
            // Not used for strict providers (Groq, Ollama) — normalizeMessage() converts to .text first.
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
            // Preserve the string as-is — empty string normalization happens in AIClient.normalizeMessage()
            // so that AITunnel (supportsCaching=true) is not affected.
            self = .text(string)
        } else if let blocks = try? container.decode([AIContentBlock].self) {
            self = .blocks(blocks)
        } else {
            // Unknown content shape — treat as empty text; normalizeMessage() will convert to nil.
            self = .text("")
        }
    }
}

// MARK: - AIMessage

/// A single message in the conversation.
///
/// content is AIMessageContent? — polymorphic (.text / .blocks / .multimodal).
/// contentString provides backward-compatible string access without manual unwrapping.
///
/// ENCODING: content uses encodeIfPresent — nil content is OMITTED from JSON (not null).
/// Strict providers (Groq, Ollama) reject "content": null on assistant tool-call messages.
/// Omitting the field entirely is the correct OpenAI spec behavior for tool-call turns.
public struct AIMessage: Sendable {
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

    /// Blocks initializer — used for system message caching on AITunnel.
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

// MARK: - AIMessage Codable

extension AIMessage: Encodable {
    private enum CodingKeys: String, CodingKey {
        case role, content, tool_calls, tool_call_id, name
    }

    /// Manual encode — uses encodeIfPresent for content so nil is OMITTED (not null).
    /// Groq and other strict providers reject "content": null on tool-call assistant messages.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(tool_calls, forKey: .tool_calls)
        try container.encodeIfPresent(tool_call_id, forKey: .tool_call_id)
        try container.encodeIfPresent(name, forKey: .name)
    }
}

extension AIMessage: Decodable {
    private enum DecodingKeys: String, CodingKey {
        case role, content, tool_calls, tool_call_id, name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        content = try container.decodeIfPresent(AIMessageContent.self, forKey: .content)
        tool_calls = try container.decodeIfPresent([AIToolCall].self, forKey: .tool_calls)
        tool_call_id = try container.decodeIfPresent(String.self, forKey: .tool_call_id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
    }
}
