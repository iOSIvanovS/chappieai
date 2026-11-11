// TerminalConfirmation.swift
// ChappieCore
//
// Confirmation mode of run_terminal: the orchestrator PAUSES the tool call, asks the user through a
// handler supplied by the app, and then continues with the real outcome (command output, or an
// explicit "user declined"). The model never sees the internal marker.
//
// Pure on purpose: the flow takes the handler and the runner as closures, so it is testable without
// an AI client, a shell or a UI.

import Foundation

/// The user's answer to a pending terminal command.
public enum TerminalDecision: Sendable, Equatable {
    case run
    case decline
}

/// Supplied by the app: shows the command to the user and suspends until they decide.
/// Must return `.decline` when the request is cancelled while waiting.
public typealias TerminalConfirmationHandler = @Sendable (PendingTerminalCommand) async -> TerminalDecision

/// One pending question to the user. The app creates a gate per command, shows the Run/Cancel prompt,
/// and the buttons call `resolve`. `wait()` also answers `.decline` when the waiting task is cancelled
/// (Stop button), including a cancel that arrives before `wait()` has registered.
public final class TerminalDecisionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TerminalDecision, Never>?
    private var early: TerminalDecision?

    public init() {}

    public func wait() async -> TerminalDecision {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<TerminalDecision, Never>) in
                lock.lock()
                if let decided = early {
                    early = nil
                    lock.unlock()
                    cont.resume(returning: decided)
                } else {
                    continuation = cont
                    lock.unlock()
                }
            }
        } onCancel: {
            resolve(.decline)
        }
    }

    /// First answer wins; later calls are ignored.
    public func resolve(_ decision: TerminalDecision) {
        lock.lock()
        if let cont = continuation {
            continuation = nil
            lock.unlock()
            cont.resume(returning: decision)
        } else {
            if early == nil { early = decision }
            lock.unlock()
        }
    }
}

enum TerminalConfirmationFlow {

    /// Turns a tool result into its final form. Anything that is not a confirmation marker of
    /// run_terminal passes through untouched.
    static func resolve(
        toolName: String,
        result: String,
        confirm: TerminalConfirmationHandler?,
        run: @Sendable (PendingTerminalCommand) async -> String
    ) async -> String {
        guard toolName == "run_terminal",
              let pending = PendingTerminalCommand.decode(from: result) else { return result }

        guard let confirm else {
            return ToolExecutionService.unconfirmableMessage(pending.command)
        }
        switch await confirm(pending) {
        case .run:
            return await run(pending)
        case .decline:
            return ToolExecutionService.declinedMessage(pending.command)
        }
    }
}
