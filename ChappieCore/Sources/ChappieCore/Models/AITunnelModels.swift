import Foundation

// MARK: - Request Model

/// POST request body for the AI provider API.
///
/// cache_control at top level is kept for compatibility but no longer used for caching.
/// Actual caching is done via per-block cache_control in the system message content array.
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
        cacheControl: AICacheControl? = nil
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.tools = tools
        self.stream = stream
        self.cache_control = cacheControl
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

// MARK: - Usage & Cache Statistics

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
