// StreamDump.swift — keeps the raw SSE stream of one request in memory and decides whether it is worth a file
import Foundation

/// One tool call as assembled from the stream, kept only for the dump.
struct StreamDumpToolCall: Sendable {
    let name: String
    let arguments: String

    /// A gateway can cut the argument fragments mid-way; an unparsable tail is itself a finding.
    var argumentsAreValidJSON: Bool {
        guard !arguments.isEmpty, let data = arguments.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }
}

/// Everything the dump needs to know about a finished stream, independent of how it was parsed.
struct StreamDumpSummary: Sendable {
    let date: Date
    let host: String
    let path: String
    let protocolName: String
    let model: String
    let upstreamModel: String?
    let upstreamProvider: String?
    let finishReason: String?
    let chunks: Int
    let skippedChunks: Int
    let firstSkippedSample: String?
    let text: String
    let toolCalls: [StreamDumpToolCall]

    /// The gateway flattened a tool call into plain content instead of sending structured deltas.
    var hasFlattenedMarker: Bool { StreamDiagnostics.containsFlattenedToolMarker(text) }
}

/// Why a stream was written to disk. Stored in the file name so a file can be found by its cause.
enum StreamDumpReason: String, Sendable, CaseIterable {
    /// Text holds the flattened tool marker — the shape RouterAI produced on 2026-11-13 and 2026-11-14.
    ///
    /// Triggered by the marker alone, not by "marker and no structured calls": if the gateway flattens
    /// one call out of several, the remaining structured calls would hide the fault from a stricter test.
    /// This only decides whether to save a file; nothing is ever parsed out of the text as a call.
    case flattenedToolCall = "flattened-tool-call"
    /// An SSE data line could not be decoded as a chunk and was dropped.
    case skippedChunks = "skipped-chunks"
    /// A tool call arrived but its accumulated arguments are not valid JSON.
    case malformedToolArguments = "malformed-tool-arguments"
    /// The stream ended without any finish_reason: the tail never arrived.
    case noFinishReason = "no-finish-reason"
    /// Saving every request was requested through CHAPPIE_STREAM_DUMP — for capturing healthy samples.
    case forced = "forced"
}

/// Buffers raw SSE lines of the current request.
///
/// WHY NOT ALWAYS WRITE: a healthy turn would cost a disk write of a few hundred kilobytes.
/// The buffer is bounded, so an endless stream cannot grow memory without limit.
struct StreamDumpRecorder: Sendable {
    /// Cap on buffered characters. A normal turn is 100–500 KB, so this only cuts pathological streams.
    static let maxCharacters = 4 * 1024 * 1024
    /// Environment variable that saves every request, not just suspicious ones.
    static let envFlagName = "CHAPPIE_STREAM_DUMP"

    private(set) var lines: [String] = []
    private(set) var characters = 0
    /// Lines seen after the cap was reached; they are counted but not kept.
    private(set) var droppedLines = 0

    var isEmpty: Bool { lines.isEmpty }

    mutating func record(_ line: String) {
        guard characters < Self.maxCharacters else {
            droppedLines += 1
            return
        }
        lines.append(line)
        characters += line.count + 1
    }

    /// True when the env flag is set to a recognised on-value.
    static var isForced: Bool {
        guard let raw = ProcessInfo.processInfo.environment[envFlagName]?.lowercased() else { return false }
        return raw == "1" || raw == "true" || raw == "yes"
    }

    /// First matching reason wins; the order runs from the most explanatory fault to the mildest.
    ///
    /// Returns nil for a healthy stream, which is what keeps the disk quiet.
    static func reason(for summary: StreamDumpSummary, forced: Bool) -> StreamDumpReason? {
        if summary.hasFlattenedMarker { return .flattenedToolCall }
        if summary.skippedChunks > 0 { return .skippedChunks }
        if summary.toolCalls.contains(where: { !$0.argumentsAreValidJSON }) { return .malformedToolArguments }
        if summary.finishReason == nil { return .noFinishReason }
        return forced ? .forced : nil
    }
}
