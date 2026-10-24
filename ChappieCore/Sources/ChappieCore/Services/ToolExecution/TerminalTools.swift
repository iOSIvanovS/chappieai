// TerminalTools.swift
// ChappieCore
//
// WHY THIS FILE:
// Execution logic for run_terminal and run_ssh tools.
//
// run_terminal:
// Manages a pool of ShellSession objects keyed by threadId.
// Each thread gets its own persistent bash session — so `cd` is stateful within a call.
// When "project" is provided, the command is prefixed with `cd /absolute/path && `
// so every call is self-contained regardless of session history.
//
// run_ssh:
// Stateless SSH execution — one command per call, one connection per call.
// WHY stateless: SSH sessions are expensive to maintain and error-prone across calls.
// Each call opens a fresh connection, runs the command, returns output, closes.
// No interactive input supported — use for remote diagnostics and server commands only.
//
// CONFIRMATION MODE (run_terminal only):
// When threadTerminalAccess == .confirm, the tool does NOT execute the command.
// Instead it returns a special PENDING_CONFIRMATION marker that the ViewModel
// intercepts and renders as an inline confirmation UI in the chat.
//
// SESSION LIFECYCLE:
// Sessions are created lazily on first use per thread.
// Sessions are cleared when a thread is deactivated (clearSession called from ViewModel).
//
// ACCESS CONTROL:
// Terminal access is thread-level — read from activeMemoryContext.threadTerminalAccess.
// No project role required. ToolPolicy handles the gate before this code runs.

import Foundation

// MARK: - PendingTerminalCommand

/// Marker returned when threadTerminalAccess == .confirm.
/// ViewModel parses this to show inline confirmation UI.
public struct PendingTerminalCommand: Codable, Sendable {
    public static let markerPrefix = "CHAPPIE_TERMINAL_CONFIRM:"

    public let command: String
    public let threadId: UUID

    public var encoded: String {
        let json = (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "\(Self.markerPrefix)\(json)"
    }

    public static func decode(from string: String) -> PendingTerminalCommand? {
        guard string.hasPrefix(markerPrefix) else { return nil }
        let json = String(string.dropFirst(markerPrefix.count))
        return try? JSONDecoder().decode(PendingTerminalCommand.self, from: Data(json.utf8))
    }
}

// MARK: - TerminalTools extension

extension ToolExecutionService {

    // MARK: - Session pool

    // WHY nonisolated(unsafe): sessions are only accessed from within the actor,
    // but Swift 6 requires explicit annotation for stored mutable state.
    nonisolated(unsafe) private static var sessions: [UUID: ShellSession] = [:]
    nonisolated(unsafe) private static var sessionsLock = NSLock()

    /// Returns the existing session for a thread or creates a new one.
    private func session(for threadId: UUID) -> ShellSession {
        Self.sessionsLock.lock()
        defer { Self.sessionsLock.unlock() }
        if let existing = Self.sessions[threadId] { return existing }
        let newSession = ShellSession(initialDirectory: "/")
        Self.sessions[threadId] = newSession
        print("[TerminalTools] 🐚 Created new shell session for thread \(threadId) at /")
        return newSession
    }

    /// Clears the shell session for a thread (call on thread deactivation).
    public func clearTerminalSession(for threadId: UUID) {
        Self.sessionsLock.lock()
        defer { Self.sessionsLock.unlock() }
        Self.sessions.removeValue(forKey: threadId)
        print("[TerminalTools] 🧹 Cleared shell session for thread \(threadId)")
    }

    // MARK: - run_terminal

    func executeTerminalTool(
        argsData: Data,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        struct Args: Decodable {
            let command: String
            let timeout: String?
            let project: String?
        }

        guard let args = try? JSONDecoder().decode(Args.self, from: argsData),
              !args.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "❌ run_terminal: 'command' argument is required and must not be empty."
        }

        let rawCommand = args.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedTimeout = args.timeout.flatMap(Double.init) ?? 300.0
        // WHY capped here, not just documented: unscoped `find` can hang for hours
        // scanning the whole filesystem — this cap makes it impossible regardless
        // of what timeout is requested, no reliance on remembering the rule.
        let timeout = ShellSession.cappedTimeout(for: rawCommand, requested: requestedTimeout)

        // Prefix with `cd /path && ` if project is specified — makes every call self-contained.
        let command: String
        if let projectName = args.project?.trimmingCharacters(in: .whitespacesAndNewlines),
           !projectName.isEmpty {
            let pathMap = activeMemoryContext.projectPathMap
            if let projectPath = pathMap[projectName] {
                command = "cd \(projectPath.shellEscaped) && \(rawCommand)"
                print("[TerminalTools] 📂 Routing to project '\(projectName)': \(projectPath)")
            } else {
                let available = pathMap.keys.sorted().map { "'\($0)'" }.joined(separator: ", ")
                if available.isEmpty {
                    return """
                    ❌ run_terminal: project '\(projectName)' not found.
                    projectPathMap is empty — no projects with resolved paths are attached.
                    Try re-attaching the project or switching threads.
                    """
                } else {
                    return """
                    ❌ run_terminal: project '\(projectName)' not found in projectPathMap.
                    Available: \(available).
                    Check that the project is attached to the thread and its folder is accessible.
                    """
                }
            }
        } else {
            command = rawCommand
        }

        if let pattern = ShellSession.dangerousPattern(in: command) {
            return """
            🚫 Command blocked: contains dangerous pattern '\(pattern)'.
            This command is unconditionally prohibited. Perform it manually in Terminal.app.
            """
        }

        // Thread-level access gate — access control already passed in ToolPolicy,
        // but confirmation mode is determined here from threadTerminalAccess.
        let terminalAccess = activeMemoryContext.threadTerminalAccess
        if terminalAccess.requiresConfirmation {
            let pending = PendingTerminalCommand(
                command: command,
                threadId: activeMemoryContext.threadId ?? UUID()
            )
            return pending.encoded
        }

        return await runLocalCommand(command, timeout: timeout, onOutput: onOutput)
    }

    /// Executes a confirmed command (called by ViewModel after user approval).
    public func executeConfirmedCommand(
        _ command: String,
        timeout: TimeInterval = 300,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async -> String {
        if let pattern = ShellSession.dangerousPattern(in: command) {
            return "🚫 Command blocked: contains dangerous pattern '\(pattern)'."
        }
        let cappedTimeout = ShellSession.cappedTimeout(for: command, requested: timeout)
        return await runLocalCommand(command, timeout: cappedTimeout, onOutput: onOutput)
    }

    private func runLocalCommand(
        _ command: String,
        timeout: TimeInterval,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async -> String {
        let threadId = activeMemoryContext.threadId ?? UUID()
        let shell = session(for: threadId)
        print("[TerminalTools] 🖥️ Running: \(command)")
        let result = await shell.run(command, timeout: timeout, onOutput: onOutput)
        print("[TerminalTools] \(result.isSuccess ? "✅" : "❌") Exit \(result.exitCode)")
        return result.formatted
    }

    // MARK: - run_ssh

    /// Stateless SSH execution — one command per connection.
    /// WHY Process + /usr/bin/ssh: reuses system SSH config and keys, no extra dependencies.
    /// WHY -o StrictHostKeyChecking=accept-new: auto-accepts new host keys without hanging.
    /// WHY -o BatchMode=yes: disables password prompts — fails fast if key auth not configured.
    func executeSSHTool(
        argsData: Data,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        struct Args: Decodable {
            let host: String
            let command: String
            let user: String?
            let port: String?
            let identity_file: String?
            let timeout: String?
        }

        guard let args = try? JSONDecoder().decode(Args.self, from: argsData),
              !args.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !args.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "❌ run_ssh: 'host' and 'command' arguments are required."
        }

        let host = args.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteCommand = args.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = args.user?.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = args.port?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identityFile = args.identity_file?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedTimeoutSeconds = args.timeout.flatMap(Int.init) ?? 30
        // WHY capped here: same rationale as run_terminal — unscoped `find` over SSH
        // can hang the remote session for hours without ever completing.
        let timeoutSeconds = ShellSession.cappedTimeoutSeconds(for: remoteCommand, requested: requestedTimeoutSeconds)

        if let pattern = ShellSession.dangerousPattern(in: remoteCommand) {
            return "🚫 SSH command blocked: contains dangerous pattern '\(pattern)'."
        }

        // Build SSH argument list — all values are immutable let constants for Swift 6 Sendable.
        var argsList: [String] = [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(timeoutSeconds)",
        ]
        if let p = port, !p.isEmpty { argsList += ["-p", p] }
        if let identity = identityFile, !identity.isEmpty {
            // WHY tilde expansion: Process does not go through a shell, so "~" is passed literally to ssh
            // unless expanded here — NSString.expandingTildeInPath handles the home directory substitution.
            argsList += ["-i", (identity as NSString).expandingTildeInPath]
        }
        let target = user.map { "\($0)@\(host)" } ?? host
        argsList.append(target)
        argsList.append(remoteCommand)

        // Capture as immutable constants before entering Task.detached.
        // WHY: Swift 6 forbids capturing mutable vars across task boundaries.
        let finalArgs: [String] = argsList
        let finalTarget = target
        let finalTimeout = timeoutSeconds

        print("[SSHTools] 🔌 Connecting to \(finalTarget)\(identityFile.map { " with identity '\($0)'" } ?? "" ), command: \(remoteCommand)")

        // Task.detached does not inherit the caller's cancellation, so Stop reaches the ssh
        // process through this canceller (the cancellation handler below).
        let canceller = ProcessCanceller()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
            Task.detached {
                let process = Process()
                let outPipe = Pipe()
                let errPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = finalArgs
                process.standardOutput = outPipe
                process.standardError = errPipe

                // WHY accumulate via lock instead of readDataToEndOfFile: readabilityHandler
                // fires live as chunks arrive over the SSH pipe, enabling onOutput streaming
                // for the live terminal UI. Final result is still built from full accumulation.
                let accumulatedLock = NSLock()
                nonisolated(unsafe) var outAccumulated = Data()
                nonisolated(unsafe) var errAccumulated = Data()

                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { return }
                    accumulatedLock.lock()
                    outAccumulated.append(chunk)
                    accumulatedLock.unlock()
                    if let chunkText = String(data: chunk, encoding: .utf8) {
                        onOutput?(chunkText)
                    }
                }
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { return }
                    accumulatedLock.lock()
                    errAccumulated.append(chunk)
                    accumulatedLock.unlock()
                    if let chunkText = String(data: chunk, encoding: .utf8) {
                        onOutput?(chunkText)
                    }
                }

                do {
                    try process.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: "❌ run_ssh: Failed to launch ssh: \(error.localizedDescription)")
                    return
                }

                // A Stop that arrived before launch finished is applied here.
                canceller.attach(pid: process.processIdentifier)

                // Wait with deadline — terminate if hung.
                let deadline = Date().addingTimeInterval(TimeInterval(finalTimeout) + 5)
                while process.isRunning && Date() < deadline && canceller.stopReason == nil {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }

                if canceller.stopReason == .cancelled {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: "🛑 run_ssh: Command cancelled by the user; the ssh connection was closed.")
                    return
                }

                if process.isRunning {
                    canceller.stop(.timedOut)
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: "⏱️ run_ssh: Command timed out after \(finalTimeout)s on \(finalTarget).")
                    return
                }

                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil

                // WHY a sync helper: NSLock.lock()/unlock() are marked noasync in Swift 6 —
                // calling them directly inside an async function body is a compile error
                // regardless of await points. Wrapping in a plain sync closure sidesteps that.
                func readAccumulated() -> (String, String) {
                    accumulatedLock.lock()
                    defer { accumulatedLock.unlock() }
                    let out = String(data: outAccumulated, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let err = String(data: errAccumulated, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return (out, err)
                }
                let (stdout, stderr) = readAccumulated()
                let exitCode = process.terminationStatus

                print("[SSHTools] \(exitCode == 0 ? "✅" : "❌") Exit \(exitCode) from \(finalTarget)")

                if exitCode == 0 {
                    let output = stdout.isEmpty ? "✅ Command completed successfully (no output)." : "✅\n\(stdout)"
                    continuation.resume(returning: output)
                } else {
                    var parts: [String] = ["❌ (exit code \(exitCode))"]
                    if !stdout.isEmpty { parts.append(stdout) }
                    if !stderr.isEmpty { parts.append("stderr: \(stderr)") }
                    continuation.resume(returning: parts.joined(separator: "\n"))
                }
            }
            }
        } onCancel: {
            canceller.stop(.cancelled)
        }
    }
}

// MARK: - String shell escaping helper

private extension String {
    /// Wraps the string in single quotes and escapes any existing single quotes.
    var shellEscaped: String {
        "'\(self.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
