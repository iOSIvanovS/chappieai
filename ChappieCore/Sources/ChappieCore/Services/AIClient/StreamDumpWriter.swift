// StreamDumpWriter.swift — writes a buffered stream to disk when the recorder decides it is worth keeping
import Foundation

/// Persists suspicious streams under Application Support/ChappieAI/StreamDumps.
///
/// WHY THE APP, NOT THE LOG: Xcode's console keeps a bounded tail, so the raw stream is gone by the
/// time someone reads the log. A file survives a restart and can be compared with the next occurrence.
///
/// PRIVACY: a dump holds the whole conversation sent to the provider, including tool arguments and
/// their results. Files stay local, are never uploaded, and old ones are pruned by count.
enum StreamDumpWriter {

    /// Files kept on disk; the oldest are deleted once this is exceeded.
    static let maxFiles = 40

    /// Directory for dumps, created on first write.
    static var directory: URL {
        get throws {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dir = appSupport
                .appendingPathComponent("ChappieAI", isDirectory: true)
                .appendingPathComponent("StreamDumps", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
    }

    /// Writes the dump and returns the file URL, or nil when nothing was written.
    ///
    /// Never throws to the caller: a failed dump must not break the answer that already arrived.
    /// `in` exists so tests write into a temporary folder instead of Application Support.
    @discardableResult
    static func write(
        recorder: StreamDumpRecorder,
        summary: StreamDumpSummary,
        reason: StreamDumpReason,
        in override: URL? = nil
    ) -> URL? {
        guard !recorder.isEmpty else { return nil }
        do {
            let dir = try override ?? directory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(fileName(date: summary.date, reason: reason))
            try text(recorder: recorder, summary: summary, reason: reason)
                .write(to: url, atomically: true, encoding: .utf8)
            prune(in: dir)
            print("[AIClient] STREAM DUMP | reason: \(reason.rawValue) | \(url.path)")
            return url
        } catch {
            print("[AIClient] STREAM DUMP FAILED | reason: \(reason.rawValue) | \(error.localizedDescription)")
            return nil
        }
    }

    /// Sorts by name, which starts with the timestamp, so pruning needs no file attributes.
    private static func prune(in dir: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let dumps = names.filter { $0.hasSuffix(".log") }.sorted()
        guard dumps.count > maxFiles else { return }
        for name in dumps.prefix(dumps.count - maxFiles) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    private static func fileName(date: Date, reason: StreamDumpReason) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "\(formatter.string(from: date))_\(reason.rawValue).log"
    }

    /// Header first, then the raw SSE lines exactly as they arrived, so nothing is lost to re-encoding.
    private static func text(
        recorder: StreamDumpRecorder,
        summary: StreamDumpSummary,
        reason: StreamDumpReason
    ) -> String {
        var out = [
            "# Chappie stream dump",
            "reason: \(reason.rawValue)",
            "date: \(ISO8601DateFormatter().string(from: summary.date))",
            "host: \(summary.host)\(summary.path)",
            "protocol: \(summary.protocolName)",
            "model: \(summary.model)"
        ]
        if let upstreamModel = summary.upstreamModel { out.append("upstreamModel: \(upstreamModel)") }
        if let provider = summary.upstreamProvider { out.append("provider: \(provider)") }
        out.append("finishReason: \(summary.finishReason ?? "none")")
        out.append("chunks: \(summary.chunks)")
        out.append("skippedChunks: \(summary.skippedChunks)")
        out.append("textChars: \(summary.text.count)")
        out.append("toolCalls: \(summary.toolCalls.count)")
        for (index, call) in summary.toolCalls.enumerated() {
            let valid = call.argumentsAreValidJSON ? "valid json" : "NOT valid json"
            out.append("  [\(index)] \(call.name) — args \(call.arguments.count) chars, \(valid)")
        }
        if let sample = summary.firstSkippedSample {
            out.append("firstSkippedSample: \(sample)")
        }
        if summary.hasFlattenedMarker {
            out.append("flattenedMarker: present in text")
        }
        if recorder.droppedLines > 0 {
            out.append("droppedLines: \(recorder.droppedLines) (buffer cap \(StreamDumpRecorder.maxCharacters) chars)")
        }

        out.append("")
        out.append("# --- assembled text ---")
        out.append(summary.text)
        out.append("")
        out.append("# --- raw SSE lines ---")
        out.append(contentsOf: recorder.lines)
        return out.joined(separator: "\n") + "\n"
    }
}
