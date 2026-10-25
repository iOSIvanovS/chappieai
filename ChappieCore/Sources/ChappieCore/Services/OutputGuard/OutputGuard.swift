// OutputGuard.swift
// ChappieCore
//
// THE single gate for "how much data may a tool result carry to the model".
//
// Every tool result passes through `apply` in ToolExecutionService.execute, so a new tool is
// covered without anyone remembering to add a size check to it. The measured quantity is the
// PREPARED result (the text that would be sent to the model), never the size of a source file:
// a 10 MB Word file with 100 KB of text is fine, a 1 MB plain-text novel is not.
//
// An oversized result is NOT cut into a head/tail/middle piece. The model receives a notice with
// the real size and the limit instead, and is told to ask the user to hand over less data.
//
// Adding a tool: nothing to register for the gate itself. Only a command-like tool (it runs
// something whose output size is unknown beforehand) must be listed in `commandTools`, because
// command output is judged by the stricter command limit and gets a different notice.

import Foundation

public enum OutputGuard {

    // MARK: - Limits

    /// Text read from files, documents, search, memory, web (bytes of the prepared UTF-8 text).
    public static let readLimit = 200 * 1024

    /// Output of commands: terminal, ssh, build, tests, git.
    public static let commandLimit = 100 * 1024

    /// How much of a running command's output collectors keep in memory. Only the size matters
    /// beyond the limit, so there is no reason to hold more than this.
    public static let captureCap = commandLimit * 2

    // MARK: - Classification

    public enum Kind: Sendable { case read, command }

    /// Tools whose result is the output of a process: its size is unknown until it has run, and it
    /// cannot be refused up front (the command already executed).
    static let commandTools: Set<String> = [
        "run_terminal", "run_ssh", "build_project", "run_tests",
        "git_status", "git_log", "git_add", "git_commit", "git_push",
        "git_reset", "git_revert", "git_checkout"
    ]

    public static func kind(of tool: String) -> Kind {
        commandTools.contains(tool) ? .command : .read
    }

    public static func limit(for kind: Kind) -> Int {
        kind == .command ? commandLimit : readLimit
    }

    // MARK: - The gate

    /// Returns `output` unchanged when it fits, otherwise the oversize notice.
    public static func apply(toolName: String, output: String) -> String {
        // view_image carries a data URI that AIOrchestrator turns into a real image part; its own
        // size rules (and the image pipeline) are separate from text limits.
        if output.hasPrefix(ToolExecutionService.viewImageMarker) { return output }

        // A collector that stopped storing output reports the real size through a marker.
        let size = truncatedTotal(in: output) ?? output.utf8.count
        guard size > limit(for: kind(of: toolName)) else { return output }
        return oversizeNotice(toolName: toolName, bytes: size)
    }

    // MARK: - Notice

    public static func oversizeNotice(toolName: String, bytes: Int) -> String {
        let kind = kind(of: toolName)
        let size = formatSize(bytes)
        let limit = formatSize(limit(for: kind))
        switch kind {
        case .read:
            return """
            ⚠️ DATA NOT PASSED. The prepared result of `\(toolName)` is \(size), over the \(limit) limit for text results.
            Tell the user that the file or result is too large to work with, and ask them to give you less data \
            (a smaller file, only the relevant part, or a narrower request). If you can narrow the request yourself \
            (a more specific search query, one folder instead of the whole project), you may retry with the narrower one. \
            Do not pretend you have seen the content.
            """
        case .command:
            return """
            ⚠️ OUTPUT NOT PASSED. `\(toolName)` has finished, but its output is \(size), over the \(limit) limit for command output.
            Tell the user, or run a narrower command (filter with grep or tail, pick one test or target). \
            If the command changes state (install, git, delete, write), check the current state first — do not re-run it blindly.
            """
        }
    }

    /// Human-readable size with a "." decimal separator regardless of locale (the text goes to a model).
    static func formatSize(_ bytes: Int) -> String {
        let kb = 1024.0, mb = kb * 1024, gb = mb * 1024
        let value = Double(bytes)
        if value < kb { return "\(bytes) B" }
        if value < mb { return String(format: "%.1f KB", value / kb) }
        if value < gb { return String(format: "%.1f MB", value / mb) }
        return String(format: "%.1f GB", value / gb)
    }

    // MARK: - Truncation marker (collector → gate)

    /// Fixed text, not a per-process secret: the helper (ChappieMCP, a separate process) writes the
    /// same marker. A file that imitates it can at worst get its own result refused.
    static let markerPrefix = "[[CHAPPIE_OUTPUT_TRUNCATED:"

    /// Appended by a collector that stopped storing output; carries the real byte count.
    public static func truncationMarker(totalBytes: Int) -> String {
        "\(markerPrefix)\(totalBytes)]]"
    }

    /// Sum of the byte counts of all collector markers in `text`, or nil when there is none.
    /// A result can hold several: ssh reports stdout and stderr separately, and its text is joined
    /// from both, so the marker is not always at the very end.
    static func truncatedTotal(in text: String) -> Int? {
        var sum = 0
        var found = false
        var from = text.startIndex
        while let hit = text.range(of: markerPrefix, range: from..<text.endIndex) {
            let rest = text[hit.upperBound...]
            let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
            if let count = Int(digits), rest[digits.endIndex...].hasPrefix("]]") {
                sum += count
                found = true
            }
            from = hit.upperBound
        }
        return found ? sum : nil
    }
}
