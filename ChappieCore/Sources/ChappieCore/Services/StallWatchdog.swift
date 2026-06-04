// StallWatchdog.swift
// ChappieCore
//
// Actor that monitors streaming silence and cancels the stream Task on timeout.
//
// SHARED BY: AIClient (OpenAI) and AnthropicClient — both use the same stall detection logic.
//
// CANCELLATION FLOW:
// 1. Watchdog timer fires → isStalled = true → cancels the registered stream Task.
// 2. Stream loop receives CancellationError.
// 3. streamRequestWithTools() checks watchdog.isStalled → throws StallError.
// 4. AIOrchestrator catches StallError → performs continuation retry.
//
// WHY ACTOR:
// The watchdog timer and the stream child Task run concurrently.
// Actor isolation prevents data races on timerTask and isStalled.

import Foundation

// MARK: - StallWatchdog

actor StallWatchdog {

    private let timeout: TimeInterval
    private var timerTask: Task<Void, Never>?
    private var streamTask: Task<Void, any Error>?

    /// True only when the watchdog fired due to silence (not stopped normally).
    private(set) var isStalled: Bool = false

    init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    // MARK: - API

    /// Registers the stream Task to cancel on stall, then starts the timer.
    func start(cancelling task: Task<Void, any Error>) {
        self.streamTask = task
        scheduleTimer()
    }

    /// Starts the timer without a pre-registered task.
    func start() {
        scheduleTimer()
    }

    /// Resets the stall timer. Call on every received streaming token.
    func reset() {
        timerTask?.cancel()
        scheduleTimer()
    }

    /// Stops the watchdog without triggering a stall (normal stream completion).
    func stop() {
        timerTask?.cancel()
        timerTask = nil
    }

    // MARK: - Private

    private func scheduleTimer() {
        timerTask = Task { [timeout] in
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                isStalled = true
                streamTask?.cancel()
                print("[StallWatchdog] Stall detected after \(timeout)s of silence.")
            } catch {
                // Cancelled via reset() or stop() — normal operation.
            }
        }
    }
}
