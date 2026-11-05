// ToolDeadlines.swift
// ChappieCore
//
// THE single table of "how long may a tool run before the watchdog gives up". Pure: no I/O.
// Used by ToolExecutionService.execute (enforcement) and by the UI (the filling bar), so both
// always agree on the number.
//
// Classes, not one global number: a build legitimately runs for many minutes, a file read that
// has not answered in two minutes is hung.

import Foundation

public enum ToolDeadlines {

    // MARK: - Table (seconds)

    /// Files, search, documents, memory, attachments, web, curl_*, localization, read_build_log.
    /// (The curl engine's own network timeout is 30 s per request; a login plus one retry fits.)
    static let standard: TimeInterval = 120
    /// git status/log/add/reset/checkout: local and short.
    static let gitLocal: TimeInterval = 180
    /// Default for run_terminal / run_ssh when the caller asked for no longer timeout.
    static let terminalBase: TimeInterval = 300
    /// A terminal call that asks for a longer timeout gets it, up to this ceiling.
    static let terminalCeiling: TimeInterval = 1800
    /// build_project / run_tests.
    static let build: TimeInterval = 1200
    /// git commit / revert (hooks) and push (network). Just above the helper's own 10 min cap,
    /// so the helper's more precise handling normally fires first.
    static let gitSlow: TimeInterval = 720

    /// Extra seconds on top of a requested terminal timeout, so the shell's own timeout (which
    /// reports partial output) fires before the watchdog does.
    static let terminalGrace: TimeInterval = 30

    // MARK: - Lookup

    /// Allowed run time of one call, in seconds.
    public static func seconds(tool: String, arguments: String) -> TimeInterval {
        switch tool {
        case "run_terminal", "run_ssh":
            guard let requested = requestedTimeout(in: arguments) else { return terminalBase }
            return min(terminalCeiling, max(terminalBase, requested + terminalGrace))
        case "build_project", "run_tests":
            return build
        case "git_commit", "git_revert", "git_push":
            return gitSlow
        case "git_status", "git_log", "git_add", "git_reset", "git_checkout":
            return gitLocal
        default:
            return standard
        }
    }

    /// The `timeout` argument as a number. Models send it as a string or a number.
    static func requestedTimeout(in arguments: String) -> TimeInterval? {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["timeout"] else { return nil }
        if let number = raw as? Double { return number }
        if let text = raw as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    // MARK: - Classification

    /// True when a call that was cut off may have changed something, so its outcome is unknown.
    public static func isMutating(_ tool: String) -> Bool {
        switch ToolPolicy.capability(of: tool) {
        case .fileWrite, .locWrite, .terminal: return true
        default: break
        }
        return [
            "git_add", "git_commit", "git_push", "git_reset", "git_revert", "git_checkout",
            "memorize", "delete_memory", "send_attachment",
            // A POST/PUT/DELETE may already have reached the server; a login changes the session.
            "curl_request", "curl_session"
        ].contains(tool)
    }

    // MARK: - Message to the model

    static func timeoutMessage(tool: String, seconds: TimeInterval) -> String {
        let limit = describe(seconds)
        if isMutating(tool) {
            return """
            ⏱️ Tool `\(tool)` did not answer within \(limit) and was stopped by the watchdog. \
            THE RESULT IS UNKNOWN: it may have taken effect fully, partly, or not at all.
            Check the current state (git_status / git_log / read_file / list_files) before any retry, and do not \
            repeat it automatically. Tell the user what happened.
            """
        }
        return """
        ⏱️ Tool `\(tool)` did not answer within \(limit) and was stopped by the watchdog. Nothing was changed.
        Tell the user. You may retry once with a narrower request (a smaller scope, a more specific query).
        """
    }

    /// "45 seconds", "1 minute", "12 minutes".
    static func describe(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            let s = Int(seconds.rounded())
            return s == 1 ? "1 second" : "\(s) seconds"
        }
        let m = Int((seconds / 60).rounded())
        return m == 1 ? "1 minute" : "\(m) minutes"
    }
}
