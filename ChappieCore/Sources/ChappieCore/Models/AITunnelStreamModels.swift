import Foundation

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
