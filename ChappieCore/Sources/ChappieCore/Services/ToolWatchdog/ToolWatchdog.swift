// ToolWatchdog.swift
// ChappieCore
//
// THE single guard against "a tool never answers". It wraps every tool call in
// ToolExecutionService.execute, so a new tool is covered without registering anything
// (same idea as OutputGuard).
//
// On expiry it cancels the tool's task (the bridge closes its socket, the helper kills the process
// tree, the shell session is killed — see backlog item 7) and returns a message to the model.
// It does NOT wait for the tool to actually finish: a call stuck in an uncancellable blocking
// system call (a dead network volume) would otherwise hold the whole reasoning chain. If such a
// tool comes back later, its result is discarded.

import Foundation

public enum ToolWatchdog {

    /// Runs `operation` for at most `seconds`. Returns its result, or the watchdog message.
    /// Cancelling the caller (Stop) is forwarded to `operation`.
    public static func run(
        toolName: String,
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> String
    ) async -> String {
        // Unstructured on purpose: a structured group would wait for a stuck operation to finish.
        let work = Task { await operation() }
        let message = ToolDeadlines.timeoutMessage(tool: toolName, seconds: seconds)
        let nanos = UInt64(max(0, seconds) * 1_000_000_000)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                let gate = OneShot()

                let timer = Task {
                    do { try await Task.sleep(nanoseconds: nanos) } catch { return }
                    guard gate.claim() else { return }
                    print("[ToolWatchdog] ⏱️ \(toolName) exceeded \(ToolDeadlines.describe(seconds)) — stopping it")
                    work.cancel()
                    continuation.resume(returning: message)
                }

                Task {
                    let result = await work.value
                    // Lost the race: the watchdog already answered, this late result is dropped.
                    guard gate.claim() else { return }
                    timer.cancel()
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            work.cancel()
        }
    }
}

/// Lets exactly one of two racing tasks resume the continuation.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func claim() -> Bool {
        lock.withLock {
            if taken { return false }
            taken = true
            return true
        }
    }
}
