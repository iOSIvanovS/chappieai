// AnthropicModels.swift
// ChappieCore
//
// Wire format models for the native Anthropic API (/v1/messages).
// Used exclusively by AnthropicClient.

import Foundation

// MARK: - Request

struct AnthropicRequest: Encodable {
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

// MARK: - Message

struct AnthropicMessage: Encodable {
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

enum AnthropicMessageContent: Encodable {
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

struct AnthropicContentBlock: Encodable {
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

struct AnthropicImageSource: Encodable {
    let type: String
    let mediaType: String
    let data: String

    enum CodingKeys: String, CodingKey {
        case type, data
        case mediaType = "media_type"
    }
}

struct AnthropicToolResultContent: Encodable {
    let type: String
    let toolUseId: String
    let content: String

    enum CodingKeys: String, CodingKey {
        case type, content
        case toolUseId = "tool_use_id"
    }
}

// MARK: - Tool Models

struct AnthropicTool: Encodable {
    let name: String
    let description: String
    let inputSchema: AnthropicToolInputSchema

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }
}

struct AnthropicToolInputSchema: Encodable {
    let type: String
    let properties: [String: AnthropicToolProperty]
    let required: [String]?
}

struct AnthropicToolProperty: Encodable {
    let type: String
    let description: String?
}

// MARK: - Streaming Event Models

struct AnthropicStreamEvent: Decodable {
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

struct AnthropicDelta: Decodable {
    let type: String
    let text: String?
    let partialJSON: String?

    enum CodingKeys: String, CodingKey {
        case type, text
        case partialJSON = "partial_json"
    }
}

struct AnthropicContentBlockInfo: Decodable {
    let type: String
    let id: String?
    let name: String?
}

// MARK: - Usage

/// Token usage and optional billing info from Anthropic / proxy responses.
/// Native Anthropic does not include costRub / balance — those are AITunnel extensions.
struct AnthropicUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?
    let costRub: Double?   // AITunnel extension
    let balance: Double?   // AITunnel extension

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case costRub = "cost_rub"
        case balance
    }
}

// MARK: - JSONValue

// Bridges [String: Any] to Codable — used for encoding tool call inputs.
enum JSONValue: Encodable, Decodable {
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
        case .int(let v):    try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v):   try container.encode(v)
        case .object(let v): try container.encode(v)
        case .array(let v):  try container.encode(v)
        case .null:          try container.encodeNil()
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self)             { self = .bool(v);   return }
        if let v = try? container.decode(Int.self)              { self = .int(v);    return }
        if let v = try? container.decode(Double.self)           { self = .double(v); return }
        if let v = try? container.decode(String.self)           { self = .string(v); return }
        if let v = try? container.decode([String: JSONValue].self) { self = .object(v); return }
        if let v = try? container.decode([JSONValue].self)      { self = .array(v);  return }
        self = .null
    }
}
