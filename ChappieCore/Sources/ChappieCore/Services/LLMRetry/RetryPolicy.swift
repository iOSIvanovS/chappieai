// RetryPolicy.swift
// ChappieCore
//
// Backoff schedule and the status object the UI shows while a request waits to be re-sent.

import Foundation

// MARK: - RetryPolicy

/// How many times and how patiently a failed LLM request is re-sent.
public struct RetryPolicy: Sendable, Equatable {

    /// Re-sends after the first failure. 5 retries = pauses of ~1, 2, 4, 8, 16 s.
    public let maxRetries: Int
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    /// Random spread (+/-) so many clients do not hammer a recovering provider in lockstep.
    public let jitterFraction: Double
    /// A provider's Retry-After above this is ignored: waiting minutes inside a chat is worse than failing.
    public let maxRetryAfter: TimeInterval

    public init(
        maxRetries: Int = 5,
        baseDelay: TimeInterval = 1,
        maxDelay: TimeInterval = 30,
        jitterFraction: Double = 0.2,
        maxRetryAfter: TimeInterval = 120
    ) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitterFraction = jitterFraction
        self.maxRetryAfter = maxRetryAfter
    }

    public static let standard = RetryPolicy()

    /// Pause before retry number `retry` (1-based). `randomUnit` is in [0, 1).
    /// The pause is counted from the moment the error was RECEIVED, not from the request start —
    /// a model may fail after a minute of thinking, and that minute must not eat the pause.
    public func delay(forRetry retry: Int, retryAfter: TimeInterval?, randomUnit: Double) -> TimeInterval {
        let exponent = Double(max(0, retry - 1))
        let exponential = min(maxDelay, baseDelay * pow(2, exponent))
        let spread = 1 + jitterFraction * (2 * randomUnit - 1)
        var delay = min(maxDelay, exponential * spread)

        if let retryAfter, retryAfter > 0, retryAfter <= maxRetryAfter {
            delay = max(delay, retryAfter)
        }
        return delay
    }
}

// MARK: - RetryStatus

/// Progress report for the UI: "Provider error 500 — retry 2 of 5 in 4s".
public struct RetryStatus: Sendable, Equatable {
    public let reason: RetryReason
    /// 1-based number of the retry about to be made.
    public let attempt: Int
    public let maxAttempts: Int
    /// Whole seconds left before the request is re-sent. 0 = being re-sent right now.
    public let secondsRemaining: Int

    public init(reason: RetryReason, attempt: Int, maxAttempts: Int, secondsRemaining: Int) {
        self.reason = reason
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.secondsRemaining = secondsRemaining
    }
}
