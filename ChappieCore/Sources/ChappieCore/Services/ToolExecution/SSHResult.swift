// SSHResult.swift
// ChappieCore
//
// WHY THIS FILE:
// Builds the model-facing text of a run_ssh call from its output collectors.
//
// Split out of TerminalTools on purpose. This is the part that decides what the model actually
// reads — the whole text, or a short notice with the path of a file holding all of it — and it has
// to behave exactly like run_terminal (ShellSession). It is a pure function over collectors, so
// the behaviour can be tested without an ssh host, which is the only way to cover it at all.
//
// WHY the spool matters here: an ssh command prints as much as a local one (a remote log cat, a
// build on the server). Without a spool the collector stops storing past OutputGuard.captureCap
// and the rest of the stream is lost with only a byte count left; and a result over the command
// limit is then refused outright by OutputGuard, so the model sees nothing at all.

import Foundation

/// Shaping of a run_ssh result. Stateless: every function reads collectors and returns text.
enum SSHResult {

    // MARK: - Output as text

    /// One collector's content as the model should see it: the text itself, or the spill notice when
    /// the stream outgrew the command limit.
    ///
    /// WHY spilledText and not text(): with a spool directory the collector keeps every byte on disk,
    /// and `text()` would hand back only the stored beginning plus a byte-count marker.
    /// No trailer marker: unlike the shell session, ssh appends nothing of its own to the stream.
    static func outputText(_ capture: OutputCapture) -> String {
        ShellSession.spilledText(capture, trailerMarker: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Finished

    /// A command that ran to the end.
    static func finished(exitCode: Int32, stdout: OutputCapture, stderr: OutputCapture) -> String {
        let out = outputText(stdout)
        if exitCode == 0 {
            return out.isEmpty ? "✅ Command completed successfully (no output)." : "✅\n\(out)"
        }
        let err = outputText(stderr)
        var parts: [String] = ["❌ (exit code \(exitCode))"]
        if !out.isEmpty { parts.append(out) }
        if !err.isEmpty { parts.append("stderr: \(err)") }
        return parts.joined(separator: "\n")
    }

    // MARK: - Stopped

    /// A command cut short by the timeout or by the user.
    ///
    /// WHY the output is included: a timeout used to report only the reason, throwing away whatever
    /// the remote host had already printed — often the log lines that explain why it hung.
    static func stopped(_ reason: String, stdout: OutputCapture, stderr: OutputCapture) -> String {
        var parts: [String] = [reason]
        let out = outputText(stdout)
        if !out.isEmpty { parts.append("--- output received before the stop ---\n\(out)") }
        let err = outputText(stderr)
        if !err.isEmpty { parts.append("--- stderr before the stop ---\n\(err)") }
        return parts.joined(separator: "\n\n")
    }
}
