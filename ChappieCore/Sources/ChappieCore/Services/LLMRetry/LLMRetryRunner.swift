// LLMRetryRunner.swift
// ChappieCore
//
// The single retry loop for LLM requests. Handles every transient failure the same way:
// HTTP 5xx/429, network drops, timeouts, stalls and streams that die mid-answer.
//
// RULES
// - Only the model request is repeated. Tools are executed by the caller, outside this loop.
// - If the user already saw part of the answer, the retry asks the model to continue it.
// - The pause is measured from the moment the error arrived, in 1 s ticks the UI can show.
// - Cancellation (Stop button, invalidated orchestrator) interrupts a pause immediately.
// - Slow failures (timeout, stall) each cost minutes of waiting, so they have a smaller cap
//   than fast ones (HTTP 500, connection reset).

import Foundation

struct LLMRetryRunner: Sendable {

    let policy: RetryPolicy
    /// Max retries for timeouts and stalls (each one burns the full request timeout).
    var slowFailureLimit: Int = 2
    /// Appended to the final error for slow failures, e.g. context size, so the user can act.
    var contextHint: String = ""
    /// Injected so tests do not wait for real seconds.
    var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    var random: @Sendable () -> Double = { Double.random(in: 0..<1) }
    /// True when the owner was invalidated (thread closed) and the loop must stop.
    var shouldAbort: @Sendable () async -> Bool = { false }

    static let continuationPrompt =
        "[SYSTEM: Your previous response was interrupted by a connection problem. " +
        "Continue EXACTLY from where you left off. " +
        "Do NOT repeat what you already wrote. " +
        "Do NOT add any preamble. Just continue the response.]"

    func run(
        history: [AIMessage],
        onRetry: (@Sendable (RetryStatus?) -> Void)?,
        attempt: ([AIMessage]) async throws -> AIStreamResult
    ) async throws -> AIStreamResult {

        var currentHistory = history
        var accumulatedText = ""
        var retriesUsed = 0
        var slowFailures = 0
        var statusShown = false
        defer { if statusShown { onRetry?(nil) } }

        while true {
            do {
                let result = try await attempt(currentHistory)
                guard !accumulatedText.isEmpty else { return result }
                return AIStreamResult(
                    text: accumulatedText + result.text,
                    toolCalls: result.toolCalls,
                    cost: result.cost,
                    balance: result.balance
                )
            } catch {
                guard case .retry(let reason, let retryAfter, let partial) = LLMFailureClassifier.classify(error) else {
                    throw Self.unwrap(error)
                }
                if await shouldAbort() { throw CancellationError() }

                // Real progress (new text reached the user) earns a fresh retry budget:
                // a long answer on a flaky link should not die just because it is long.
                if !partial.isEmpty {
                    retriesUsed = 0
                    slowFailures = 0
                    accumulatedText += partial
                    currentHistory.append(AIMessage(role: "assistant", content: partial))
                    currentHistory.append(AIMessage(role: "user", content: Self.continuationPrompt))
                }

                let isSlow = reason == .stall || reason == .timeout
                retriesUsed += 1
                if isSlow { slowFailures += 1 }

                if retriesUsed > policy.maxRetries || (isSlow && slowFailures > slowFailureLimit) {
                    print("[LLMRetry] Giving up after \(retriesUsed - 1) retries: \(error.localizedDescription)")
                    throw exhausted(error, slow: isSlow)
                }

                let delay = policy.delay(forRetry: retriesUsed, retryAfter: retryAfter, randomUnit: random())
                print("[LLMRetry] \(reason) — retry \(retriesUsed)/\(policy.maxRetries) in \(String(format: "%.1f", delay))s. Error: \(error.localizedDescription)")

                statusShown = true
                try await wait(delay, reason: reason, retry: retriesUsed, onRetry: onRetry)
                if await shouldAbort() { throw CancellationError() }
            }
        }
    }

    // MARK: - Waiting

    private func wait(
        _ delay: TimeInterval,
        reason: RetryReason,
        retry: Int,
        onRetry: (@Sendable (RetryStatus?) -> Void)?
    ) async throws {
        var remaining = delay
        while remaining > 0 {
            onRetry?(RetryStatus(
                reason: reason,
                attempt: retry,
                maxAttempts: policy.maxRetries,
                secondsRemaining: Int(remaining.rounded(.up))
            ))
            let step = min(1, remaining)
            try await sleep(step)
            remaining -= step
            if await shouldAbort() { throw CancellationError() }
        }
        onRetry?(RetryStatus(reason: reason, attempt: retry, maxAttempts: policy.maxRetries, secondsRemaining: 0))
    }

    // MARK: - Error shaping

    /// Callers should see the provider's real error, not our internal wrapper.
    static func unwrap(_ error: Error) -> Error {
        (error as? StreamInterruptedError)?.underlying ?? error
    }

    /// The error shown after the last retry failed.
    private func exhausted(_ error: Error, slow: Bool) -> Error {
        let inner = Self.unwrap(error)
        guard slow else { return inner }
        let what = inner is StallError ? "stopped responding" : "did not answer in time"
        let hint = contextHint.isEmpty ? "" : " \(contextHint)"
        return ChappieError.networkError(
            "The provider \(what) several times in a row.\(hint) Try again later, " +
            "start a new thread, or shorten the context in thread settings."
        )
    }
}
