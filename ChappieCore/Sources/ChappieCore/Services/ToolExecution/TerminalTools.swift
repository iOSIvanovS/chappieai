// TerminalTools.swift
// ChappieCore
//
// WHY THIS FILE:
// Execution logic for run_terminal tool.
// Manages a pool of ShellSession objects keyed by threadId.
// Each thread gets its own persistent bash session — so `cd` is stateful within a call.
//
// PROJECT PARAMETER:
// When "project" is provided, the command is prefixed with `cd /absolute/path && `
// so every call is self-contained regardless of session history.
// The path is resolved from activeProjectPathMap (name → absolute path).
// WHY: prevents "where am I?" confusion when multiple projects are attached.
//
// CONFIRMATION MODE:
// When terminalAccess == .confirm, the tool does NOT execute the command.
// Instead it returns a special PENDING_CONFIRMATION marker that the ViewModel
// intercepts and renders as an inline confirmation UI in the chat.
// Only after the user taps "Run" does the ViewModel call executeConfirmedCommand().
//
// SESSION LIFECYCLE:
// Sessions are created lazily on first use per thread.
// Sessions are cleared when a thread is deactivated (clearSession called from ViewModel).
// WHY: stale sessions waste memory and may hold open file handles.
//
// WORKING DIRECTORY:
// Without "project" — sessions start at filesystem root "/".
// With "project" — each command is prefixed with `cd /absolute/path && `.
// WHY: deterministic, no reliance on previous cd state.
//
// TIMEOUT:
// Default timeout is 300s (5 min) — enough for apt-get install, pip install, git clone etc.
// For quick commands the shell returns immediately upon sentinel detection.
// User can override via the `timeout` parameter in the tool call.

import Foundation

// MARK: - PendingTerminalCommand

/// Marker returned when terminalAccess == .confirm.
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
    // The actor's isolation guarantees thread safety — the annotation is correct here.
    nonisolated(unsafe) private static var sessions: [UUID: ShellSession] = [:]
    nonisolated(unsafe) private static var sessionsLock = NSLock()

    /// Returns the existing session for a thread or creates a new one.
    /// WHY "/": terminal always starts at filesystem root so absolute paths always work,
    /// regardless of where projects are located on disk.
    private func session(for threadId: UUID) -> ShellSession {
        Self.sessionsLock.lock()
        defer { Self.sessionsLock.unlock() }

        if let existing = Self.sessions[threadId] {
            return existing
        }
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

    // MARK: - run_terminal execution

    func executeTerminalTool(argsData: Data) async throws -> String {
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
        // WHY 300: default covers slow operations (apt-get, pip install, git clone).
        // Shell returns immediately on sentinel — fast commands are not delayed.
        let timeout = args.timeout.flatMap(Double.init) ?? 300.0

        // Resolve final command — prefix with `cd /path && ` if project is specified.
        let command: String
        if let projectName = args.project?.trimmingCharacters(in: .whitespacesAndNewlines),
           !projectName.isEmpty {
            let pathMap = activeMemoryContext.projectPathMap
            if let projectPath = pathMap[projectName] {
                // Prefix with cd so the command runs in the correct project directory,
                // regardless of where the persistent session currently is.
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

        // LAST-RESORT SAFETY: block unconditionally dangerous commands.
        if let pattern = ShellSession.dangerousPattern(in: command) {
            return """
            🚫 Command blocked: contains dangerous pattern '\(pattern)'.
            This command is unconditionally prohibited regardless of settings.
            If you need this operation, perform it manually in Terminal.app.
            """
        }

        let settings = activeProjectSettings

        // Should not reach here if ToolAccessControl did its job, but double-check.
        guard settings.terminalAccess.isEnabled else {
            return "❌ Terminal is disabled for this project. Enable it in project settings → Terminal."
        }

        // CONFIRMATION MODE: return a pending marker instead of executing.
        // ViewModel will render inline confirmation UI and call back with approval.
        if settings.terminalAccess.requiresConfirmation {
            let pending = PendingTerminalCommand(
                command: command,
                threadId: activeMemoryContext.threadId ?? UUID()
            )
            return pending.encoded
        }

        // AUTO MODE: execute immediately.
        return await runCommand(command, timeout: timeout)
    }

    /// Executes a confirmed command (called by ViewModel after user approval).
    /// WHY 300: same reasoning as executeTerminalTool — covers slow confirmed operations.
    public func executeConfirmedCommand(_ command: String, timeout: TimeInterval = 300) async -> String {
        // Re-check dangerous patterns even on confirmed commands — belt and suspenders.
        if let pattern = ShellSession.dangerousPattern(in: command) {
            return "🚫 Command blocked: contains dangerous pattern '\(pattern)'."
        }
        return await runCommand(command, timeout: timeout)
    }

    // MARK: - Internal execution

    private func runCommand(_ command: String, timeout: TimeInterval) async -> String {
        let threadId = activeMemoryContext.threadId ?? UUID()
        let shell = session(for: threadId)

        print("[TerminalTools] 🖥️ Running: \(command)")
        let result = await shell.run(command, timeout: timeout)
        print("[TerminalTools] \(result.isSuccess ? "✅" : "❌") Exit \(result.exitCode)")

        return result.formatted
    }
}

// MARK: - String shell escaping helper

private extension String {
    /// Wraps the string in single quotes and escapes any existing single quotes.
    /// WHY: paths with spaces or special characters must be quoted for safe shell use.
    var shellEscaped: String {
        "'\(self.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
