// StreamDiagnostics.swift — per-request trace of an SSE stream, so a bad turn can be explained from the log
import Foundation

/// Collects facts about one streamed response: how it ended, what was skipped, what the gateway reported.
/// Pure value type: no I/O, the caller decides when to print.
struct StreamDiagnostics: Sendable {
    /// Text marker that some gateways emit when they flatten a tool call into plain content.
    static let flattenedToolMarker = "[tool_use id="
    /// Raw skipped chunk is cut to this many characters in the log.
    static let sampleLimit = 300

    private(set) var chunks = 0
    private(set) var skippedChunks = 0
    private(set) var firstSkippedSample: String?
    private(set) var finishReason: String?
    private(set) var upstreamModel: String?
    private(set) var upstreamProvider: String?

    mutating func record(_ chunk: AIStreamChunk) {
        chunks += 1
        if let model = chunk.model, !model.isEmpty { upstreamModel = model }
        if let provider = chunk.provider, !provider.isEmpty { upstreamProvider = provider }
        for choice in chunk.choices {
            if let reason = choice.finish_reason, !reason.isEmpty { finishReason = reason }
        }
    }

    /// A data line that could not be decoded as a chunk and was dropped.
    mutating func recordSkipped(_ raw: String) {
        skippedChunks += 1
        if firstSkippedSample == nil {
            firstSkippedSample = String(raw.prefix(Self.sampleLimit))
        }
    }

    static func containsFlattenedToolMarker(_ text: String) -> Bool {
        text.contains(flattenedToolMarker)
    }

    /// One log line; the flattened-tool-call warning is added when text holds the marker but no structured call exists.
    func summary(textChars: Int, structuredToolCalls: Int, textHasToolMarker: Bool, host: String, model: String) -> String {
        var parts = [
            "[AIClient] STREAM END",
            "finish: \(finishReason ?? "none")",
            "chunks: \(chunks)",
            "skipped: \(skippedChunks)",
            "text: \(textChars) chars",
            "toolCalls: \(structuredToolCalls)",
            "host: \(host)",
            "model: \(model)"
        ]
        if let upstreamModel, upstreamModel != model { parts.append("upstreamModel: \(upstreamModel)") }
        if let upstreamProvider { parts.append("provider: \(upstreamProvider)") }
        var line = parts.joined(separator: " | ")
        if textHasToolMarker && structuredToolCalls == 0 {
            line += "\n[AIClient] WARNING flattened tool call: text contains '\(Self.flattenedToolMarker)' but no structured tool_calls arrived"
        }
        if let sample = firstSkippedSample {
            line += "\n[AIClient] first skipped chunk: \(sample)"
        }
        return line
    }
}
