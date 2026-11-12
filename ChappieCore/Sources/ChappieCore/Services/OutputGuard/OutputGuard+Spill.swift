// OutputGuard+Spill.swift
// ChappieCore
//
// What the model receives when a command printed more than the command limit and the full output
// went to a file (OutputSpool): size, the beginning, the end, the path and how to search the rest.
//
// The hint names terminal commands, not search_in_file: file tools accept project-relative paths
// only, and the spool folder is outside every project.

import Foundation

extension OutputGuard {

    /// How much of each end of a spooled output is shown to the model.
    public static let spillEdgeBytes = 8 * 1024

    /// Text for the model. `head` is the stored beginning of the stream.
    public static func spillNotice(head: String, summary: OutputSpool.Summary) -> String {
        let path = summary.url.path
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let size = formatSize(summary.bytes)

        var lines: [String] = []
        if summary.isIncomplete {
            lines.append("⚠️ OUTPUT TOO LONG TO SHOW, AND THE FILE IS INCOMPLETE: it holds only the first \(size) (\(summary.lines) lines) of what the command printed. The rest was dropped. Saved to: \(path)")
        } else {
            lines.append("⚠️ OUTPUT TOO LONG TO SHOW: \(size), \(summary.lines) lines. The full output is saved to: \(path)")
        }
        lines.append("Only the first and last parts are shown below; the middle is NOT shown, so do not assume the command printed nothing important there.")
        lines.append("Search the file instead of re-running the command: grep -n -i -E 'error|fail' \(quoted) | head -50 ; sed -n '100,160p' \(quoted) ; tail -n 80 \(quoted). The file is deleted automatically after a day.")
        lines.append("--- BEGINNING ---")
        lines.append(edgeHead(of: head, maxBytes: spillEdgeBytes))
        lines.append("--- END ---")
        lines.append(summary.tailText.trimmingCharacters(in: .newlines))
        return lines.joined(separator: "\n")
    }

    /// First `maxBytes` of `text`, cut at the last complete line when it is longer.
    static func edgeHead(of text: String, maxBytes: Int) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > maxBytes else { return text.trimmingCharacters(in: .newlines) }
        var piece = Array(bytes.prefix(maxBytes))
        if let newline = piece.lastIndex(of: 0x0A) { piece = Array(piece[..<newline]) }
        return String(decoding: piece, as: UTF8.self)
    }
}
