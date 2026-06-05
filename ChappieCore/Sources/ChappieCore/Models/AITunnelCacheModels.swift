import Foundation

// MARK: - Prompt Caching: Content Blocks

/// Cache control tag — placed inside a content block for explicit cache breakpoints.
///
/// WHY PER-BLOCK (not top-level): top-level cache_control only works when AITunnel routes
/// to Anthropic directly. When routed via Bedrock/Vertex (sticky routing fallback),
/// top-level is silently ignored. Per-block cache_control works on ALL routing targets.
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

/// One content block — text with optional cache breakpoint tag.
///
/// Used in two ways:
/// 1. System message caching: AIClient wraps the system prompt in a single block with
///    cache_control=oneHour — pins the breakpoint at the end of the system prompt.
/// 2. Response decoding: models may return content as blocks; decoded but not re-sent.
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
