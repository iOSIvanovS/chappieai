// ShellSession.swift
// ChappieCore
//
// WHY THIS FILE:
// Persistent bash session per thread. Unlike one-shot Process calls,
// a session remembers the working directory — so `cd` actually works
// and subsequent commands run in the right folder.
//
// DESIGN:
// Each thread gets its own ShellSession keyed by threadId.
// The session launches `bash -l` (login shell — loads .bashrc/.zshrc PATH),
// communicates via stdin/stdout pipes, and tracks the current directory
// by injecting a sentinel after each command.
//
// TIMEOUT:
// Each command has a configurable timeout (default 30s).
// On timeout the session is killed and recreated on next use.
//
// DANGEROUS COMMANDS:
// A static blocklist prevents the most destructive operations regardless
// of TerminalAccessLevel. This is a last-resort safety net, not the primary guard.
// Primary guard is TerminalAccessLevel in ProjectSettings + ToolAccessControl.

import Foundation

// MARK: - ShellSession

/// A persistent bash session with stateful working directory.
public actor ShellSession {

    // MARK: - State

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?

    /// Starting directory — set to project workspace root when session is created.
    private let initialDirectory: String

    // Unique sentinel printed after each command to detect output end.
    private let sentinel = "___CHAPPIE_CMD_DONE_\(UUID().uuidString.prefix(8))___"

    // MARK: - Dangerous command patterns (last-resort guard)

    // WHY STATIC: these are unconditionally blocked regardless of any settings.
    // They represent irreversible system-level operations that no AI should run autonomously.
    static let dangerousPatterns: [String] = [
        "rm -rf /",
        "rm -rf ~",
        "sudo rm",
        "mkfs",
        "dd if=",
        "> /dev/sd",
        "> /dev/disk",
        "shutdown",
        "reboot",
        "halt",
        "curl | bash",
        "curl | sh",
        "wget | bash",
        "wget | sh",
        ":(){ :|:& };:",   // fork bomb
        "chmod -R 777 /",
        "chmod 777 /",
    ]

    // MARK: - Init

    public init(initialDirectory: String) {
        self.initialDirectory = initialDirectory
    }

    // MARK: - Public API

    /// Checks if a command contains any dangerous pattern.
    /// Returns the matched pattern if dangerous, nil if safe.
    public static func dangerousPattern(in command: String) -> String? {
        let lower = command.lowercased()
        for pattern in dangerousPatterns {
            if lower.contains(pattern.lowercased()) {
                return pattern
            }
        }
        return nil
    }

    /// Executes a shell command and returns its output.
    ///
    /// - Parameters:
    ///   - command: Shell command string (passed to bash -c).
    ///   - timeout: Max seconds to wait for output (default 30).
    /// - Returns: Combined stdout+stderr output, trimmed.
    public func run(_ command: String, timeout: TimeInterval = 30) async -> ShellResult {
        // Ensure session is alive.
        if process == nil || process?.isRunning == false {
            startSession()
        }

        guard let stdin = stdinPipe?.fileHandleForWriting,
              let stdout = stdoutPipe?.fileHandleForReading else {
            return ShellResult(output: "❌ Failed to start shell session.", exitCode: -1)
        }

        // Inject command + sentinel so we know when output ends.
        // WHY `; echo $?` before sentinel: captures real exit code inline.
        let wrapped = """
        \(command)
        echo "EXIT_CODE:$?"
        echo "\(sentinel)"
        """

        guard let data = (wrapped + "\n").data(using: .utf8) else {
            return ShellResult(output: "❌ Failed to encode command.", exitCode: -1)
        }

        do {
            try stdin.write(contentsOf: data)
        } catch {
            // Pipe broken — session died. Kill and report.
            killSession()
            return ShellResult(output: "❌ Shell session pipe broken: \(error.localizedDescription)", exitCode: -1)
        }

        // Capture sentinel as a local copy so the detached task doesn't capture self.
        let sentinelCopy = sentinel

        // Read output until sentinel appears or timeout expires.
        return await readUntilSentinel(from: stdout, sentinel: sentinelCopy, timeout: timeout)
    }

    // MARK: - Session lifecycle

    private func startSession() {
        let p = Process()
        let inPipe = Pipe()
        let outPipe = Pipe()

        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-l"]           // login shell — loads PATH from profile
        p.currentDirectoryURL = URL(fileURLWithPath: initialDirectory)
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = outPipe      // merge stderr into stdout for simplicity

        do {
            try p.launch()
        } catch {
            print("[ShellSession] ❌ Failed to launch bash: \(error)")
            return
        }

        self.process = p
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe

        print("[ShellSession] ✅ Started bash session in \(initialDirectory)")
    }

    private func killSession() {
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        print("[ShellSession] 🔴 Session killed")
    }

    // MARK: - Output reading

    private func readUntilSentinel(
        from handle: FileHandle,
        sentinel: String,
        timeout: TimeInterval
    ) async -> ShellResult {
        // Read in a detached task so we can enforce timeout.
        // WHY detached: avoids inheriting the actor's executor — the polling loop
        // must not block the actor while waiting for output.
        return await withCheckedContinuation { continuation in
            let deadline = Date().addingTimeInterval(timeout)

            Task.detached {
                var accumulated = Data()

                // Polling loop — reads available bytes until sentinel or timeout.
                // 50ms sleep — fast enough for terminal output, low CPU.
                while Date() < deadline {
                    let chunk = handle.availableData
                    if !chunk.isEmpty {
                        accumulated.append(chunk)
                        if let text = String(data: accumulated, encoding: .utf8),
                           text.contains(sentinel) {
                            // Parse is a free function — no actor isolation needed.
                            let result = ShellSession.parseOutput(text, sentinel: sentinel)
                            continuation.resume(returning: result)
                            return
                        }
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                }

                // Timeout — session may be hung; caller will kill it on next use.
                let partial = String(data: accumulated, encoding: .utf8) ?? ""
                continuation.resume(returning: ShellResult(
                    output: "⏱️ Command timed out.\nPartial output:\n\(partial)",
                    exitCode: -1
                ))
            }
        }
    }

    /// Extracts clean output and exit code from sentinel-wrapped output.
    /// Static + nonisolated so it can be called from Task.detached without capturing self.
    private static func parseOutput(_ raw: String, sentinel: String) -> ShellResult {
        // Split on sentinel — take everything before it.
        let parts = raw.components(separatedBy: sentinel)
        let output = parts.first ?? raw

        // Extract EXIT_CODE line injected after command.
        var exitCode = 0
        var cleanLines: [String] = []
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("EXIT_CODE:"),
               let code = Int(line.dropFirst("EXIT_CODE:".count).trimmingCharacters(in: .whitespaces)) {
                exitCode = code
            } else {
                cleanLines.append(line)
            }
        }
        let cleanOutput = cleanLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return ShellResult(output: cleanOutput, exitCode: exitCode)
    }
}

// MARK: - ShellResult

/// Result of a shell command execution.
public struct ShellResult: Sendable {
    public let output: String
    public let exitCode: Int

    public var isSuccess: Bool { exitCode == 0 }

    /// Formatted string for AI consumption.
    public var formatted: String {
        if output.isEmpty {
            return isSuccess
                ? "✅ Command completed successfully (no output)."
                : "❌ Command failed (exit code \(exitCode), no output)."
        }
        let status = isSuccess ? "✅" : "❌ (exit code \(exitCode))"
        return "\(status)\n\(output)"
    }
}
