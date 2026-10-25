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
// Primary guard is TerminalAccessLevel in ProjectSettings + ToolPolicy.

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

    // MARK: - Find command safety cap

    // WHY: unscoped `find /` (no -maxdepth, no starting directory) can scan network
    // mounts, Time Machine snapshots, and system volumes for hours without ever finding
    // anything — this happened in practice and burned real time. This cap is enforced
    // at the tool level so it applies regardless of what the AI or caller requests,
    // independent of memory/instructions that can be forgotten across context windows.
    private static let findCommandPattern = try? NSRegularExpression(pattern: "\\bfind\\b")

    /// True if the command invokes `find` as a standalone word (not `mdfind`, etc).
    static func containsFindCommand(_ command: String) -> Bool {
        guard let regex = findCommandPattern else { return false }
        let range = NSRange(command.startIndex..., in: command)
        return regex.firstMatch(in: command, range: range) != nil
    }

    /// Caps the requested timeout to 60s when the command uses `find`.
    public static func cappedTimeout(for command: String, requested: TimeInterval) -> TimeInterval {
        guard containsFindCommand(command) else { return requested }
        return min(requested, 60)
    }

    /// Int-timeout variant for tools that use whole seconds (e.g. run_ssh).
    public static func cappedTimeoutSeconds(for command: String, requested: Int) -> Int {
        guard containsFindCommand(command) else { return requested }
        return min(requested, 60)
    }

    /// Executes a shell command and returns its output.
    ///
    /// - Parameters:
    ///   - command: Shell command string (passed to bash -c).
    ///   - timeout: Max seconds to wait for output (default 30).
    ///   - onOutput: Optional callback invoked with each raw chunk as it arrives,
    ///     before the command finishes. Used for live terminal UI streaming.
    ///     Final return value is unaffected — kept for backward compatibility.
    /// - Returns: Combined stdout+stderr output, trimmed.
    public func run(
        _ command: String,
        timeout: TimeInterval = 30,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async -> ShellResult {
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
        return await readUntilSentinel(from: stdout, sentinel: sentinelCopy, timeout: timeout, onOutput: onOutput)
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
            try p.run()
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
        // The whole tree, not just bash: a running command (build, sleep, ssh...) is its child.
        if let pid = process?.processIdentifier { ProcessTree.terminate(rootPid: pid) }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        print("[ShellSession] 🔴 Session killed")
    }

    // MARK: - Output reading

    private func readUntilSentinel(
        from handle: FileHandle,
        sentinel: String,
        timeout: TimeInterval,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async -> ShellResult {
        // WHY readabilityHandler instead of polling `handle.availableData` in a loop:
        // `availableData` BLOCKS synchronously until bytes arrive. If the command hangs
        // with no output for a long stretch (e.g. `find` piped through `grep`/`head`
        // buffering), the polling thread gets stuck inside that blocking call and the
        // `Date() < deadline` check is never re-evaluated — the timeout silently never
        // fires no matter what value is passed in. This happened in practice: a capped
        // 60s timeout still hung for ~30 minutes. readabilityHandler is event-driven
        // (GCD dispatch source under the hood) so it never blocks the watchdog timer.
        let box = SentinelReadBox()
        var timedOut = false

        // Stop in the UI cancels this task. The wait below would otherwise run until the command
        // finished or timed out (up to 5 minutes), while the shell keeps working. The process
        // tree itself is stopped by killSession() right after this returns.
        let result: ShellResult = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
            box.installCancelAction {
                guard box.markResumedIfNeeded() else { return }
                handle.readabilityHandler = nil
                box.markCancelled()
                let partial = box.capture.text()
                continuation.resume(returning: ShellResult(
                    output: "🛑 Command cancelled by the user; the shell session was stopped.\nPartial output:\n\(partial)",
                    exitCode: -1
                ))
            }
            handle.readabilityHandler = { fh in
                let chunk = fh.availableData
                guard !chunk.isEmpty else { return }
                // Only the trailing window is decoded to look for the sentinel; the capture itself
                // stops storing after OutputGuard.captureCap, so a runaway command cannot grow memory.
                let tail = box.capture.append(chunk)
                // Stream raw chunk immediately for live UI — sentinel/exit-code
                // noise is stripped only from the final parsed result, not here.
                if let chunkText = String(data: chunk, encoding: .utf8) {
                    onOutput?(chunkText)
                }
                if tail.contains(sentinel) {
                    guard box.markResumedIfNeeded() else { return }
                    handle.readabilityHandler = nil
                    continuation.resume(returning: ShellSession.parseOutput(box.capture, sentinel: sentinel))
                }
            }

            // Watchdog — independent wall-clock timer, never blocked by the read side.
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                guard box.markResumedIfNeeded() else { return }
                handle.readabilityHandler = nil
                box.markTimedOut()
                let partial = box.capture.text()
                continuation.resume(returning: ShellResult(
                    output: "⏱️ Command timed out after \(Int(timeout))s.\nPartial output:\n\(partial)",
                    exitCode: -1
                ))
            }
            }
        } onCancel: {
            box.cancel()
        }

        timedOut = box.wasTimedOut()
        if timedOut || box.wasCancelled() {
            // Actually kill the hung or cancelled session (not just document the intent) so the
            // next call starts a fresh bash process instead of reusing a stuck one. The tree kill
            // also takes down whatever the command had started.
            killSession()
        }
        return result
    }

    /// Extracts clean output and exit code from sentinel-wrapped output.
    /// Static + nonisolated so it can be called from Task.detached without capturing self.
    static func parseOutput(_ capture: OutputCapture, sentinel: String) -> ShellResult {
        // Normal case: everything fit, parse the whole text.
        // Truncated case: the middle was not stored, so the exit code is read from the tail window and
        // the stored head is returned with the size marker; OutputGuard then replaces it with a notice.
        let truncated = capture.isTruncated
        let raw = truncated ? capture.tailText : capture.headText

        // Split on sentinel — take everything before it.
        let output = raw.components(separatedBy: sentinel).first ?? raw

        // Extract EXIT_CODE line injected after command.
        var exitCode = 0
        var cleanLines: [String] = []
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("EXIT_CODE:"),
               let code = Int(line.dropFirst("EXIT_CODE:".count).trimmingCharacters(in: .whitespaces)) {
                exitCode = code
            } else if !truncated {
                cleanLines.append(line)
            }
        }
        if truncated {
            let stored = capture.headText + "\n" + OutputGuard.truncationMarker(totalBytes: capture.totalBytes)
            return ShellResult(output: stored, exitCode: exitCode)
        }
        let cleanOutput = cleanLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return ShellResult(output: cleanOutput, exitCode: exitCode)
    }
}

// MARK: - SentinelReadBox

/// Thread-safe accumulator shared between the readabilityHandler callback and the
/// watchdog timer task. A plain class + NSLock (not actor) because readabilityHandler
/// fires synchronously from a GCD dispatch source, not from an async context.
private final class SentinelReadBox: @unchecked Sendable {
    private let lock = NSLock()
    /// Output collector with its own lock and a memory cap (see OutputCapture).
    let capture = OutputCapture()
    private var resumed = false
    private var timedOut = false
    private var cancelled = false
    private var cancelAction: (@Sendable () -> Void)?
    private var cancelRequested = false

    /// Registers what to do on Stop. If Stop already arrived, it runs immediately.
    func installCancelAction(_ action: @escaping @Sendable () -> Void) {
        let runNow: Bool = lock.withLock {
            cancelAction = action
            return cancelRequested
        }
        if runNow { action() }
    }

    /// Called from the task's cancellation handler.
    func cancel() {
        let action: (@Sendable () -> Void)? = lock.withLock {
            cancelRequested = true
            return cancelAction
        }
        action?()
    }

    func markCancelled() { lock.withLock { cancelled = true } }
    func wasCancelled() -> Bool { lock.withLock { cancelled } }

    /// Returns true only the first time it's called — guards against double-resume
    /// when both the readabilityHandler and the watchdog race to finish.
    func markResumedIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }

    func markTimedOut() {
        lock.lock()
        defer { lock.unlock() }
        timedOut = true
    }

    func wasTimedOut() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
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
