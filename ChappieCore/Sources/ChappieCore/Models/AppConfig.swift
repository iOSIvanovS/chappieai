// AppConfig.swift
// ChappieCore
//
// Centralized application configuration — all magic numbers live here.
//
// DYNAMIC CONFIG (IT-02):
// AppConfig is created from thread settings, not a global singleton.
// Each thread gets its own config. AIOrchestrator.process() accepts config as a parameter.
//
// KEY PARAMETER HISTORY (for context, not to be repeated):
// - tokenBudget: 30,000 → 12,000 → 6,000 → dynamic (maxMessages × 500)
// - summaryThreshold: 800 → 400 → 200
// - stallTimeoutSeconds: 60 → 180 → 300 (claude-sonnet-4.6 can think silently for 60s+)

import Foundation

/// Centralized application configuration. All tuning parameters live here.
///
/// DYNAMIC (IT-02): Created from ThreadSettings — each thread has its own config.
/// AppConfig.shared is the default (20 messages = 10,000 tokens).
public struct AppConfig: Codable, Equatable, Sendable {

    // MARK: - Singleton

    /// Default config — used when thread has no custom settings.
    public static let shared = AppConfig()

    // MARK: - Parameters

    /// Guards against infinite loops if the model gets stuck on tool calls. Hardcoded.
    public let maxOrchestratorSteps: Int

    /// Max token budget for history sent to LLM.
    /// Formula: maxMessagesInContext × 500. Int.max when isUnlimitedContext = true.
    public let tokenBudget: Int

    /// Hard limit on message count in context window.
    ///
    /// WHY SEPARATE FROM tokenBudget: tokenBudget controls volume, not count.
    /// 30 short summary-messages fit in budget but provide poor semantic context.
    public let maxMessagesInContext: Int

    /// When true — tokenBudget and maxMessagesInContext are both Int.max. No trimming.
    public let isUnlimitedContext: Bool

    /// When false — old AI messages are never compressed to their <summary> content.
    /// Mirrors ThreadSettings.useMessageCompression. Default: true.
    public let useMessageCompression: Bool

    /// Most recent N messages always sent fully, never replaced by summaries.
    /// 3 = current task + Chappie's last action + current step. Hardcoded.
    public let recentFullMessages: Int

    /// Minimum message size (in estimateTokens units) to be eligible for summarization.
    /// 200 units ≈ ~130-260 chars. Shorter messages aren't worth summarizing. Hardcoded.
    public let summaryThreshold: Int

    /// API response timeout. 300s covers multi-file refactoring tasks. Hardcoded.
    public let requestTimeoutSeconds: TimeInterval

    /// Connection establishment timeout. 30s = clear network issue. Hardcoded.
    public let connectionTimeoutSeconds: TimeInterval

    /// Stall detector: cancels stream if no tokens arrive for this duration.
    ///
    /// WHY 300s: claude-sonnet-4.6 with large context can silently "think" for 60s+ before
    /// emitting the first token. 60s and 180s both triggered false positives. Hardcoded.
    public let stallTimeoutSeconds: TimeInterval

    /// Max stall-triggered retries per orchestrator step. 2 = handles transient hiccups. Hardcoded.
    public let maxStallRetries: Int

    // MARK: - Initialization

    /// Default config: 20 messages, 10,000 tokens.
    private init() {
        maxOrchestratorSteps     = 100
        maxMessagesInContext     = 20
        tokenBudget              = 20 * 500
        isUnlimitedContext       = false
        useMessageCompression    = true
        recentFullMessages       = 3
        summaryThreshold         = 200
        requestTimeoutSeconds    = 300
        connectionTimeoutSeconds = 30
        stallTimeoutSeconds      = 300
        maxStallRetries          = 2
    }

    /// Creates config from thread settings. tokenBudget = maxMessagesInContext × 500.
    public init(settings: ThreadSettings) {
        maxOrchestratorSteps     = 100
        isUnlimitedContext       = settings.isUnlimitedContext
        useMessageCompression    = settings.useMessageCompression
        recentFullMessages       = 3
        summaryThreshold         = 200
        requestTimeoutSeconds    = 300
        connectionTimeoutSeconds = 30
        stallTimeoutSeconds      = 300
        maxStallRetries          = 2

        if settings.isUnlimitedContext {
            maxMessagesInContext = Int.max
            tokenBudget          = Int.max
        } else {
            // Clamp to valid range — guard against corrupted JSON values
            let clamped          = max(10, min(1000, settings.maxMessagesInContext))
            maxMessagesInContext  = clamped
            tokenBudget          = clamped * 500
        }
    }

    /// Convenience init from raw message count — for tests and legacy code.
    public init(maxMessagesInContext: Int) {
        let clamped              = max(10, min(1000, maxMessagesInContext))
        maxOrchestratorSteps     = 100
        self.maxMessagesInContext = clamped
        tokenBudget              = clamped * 500
        isUnlimitedContext       = false
        useMessageCompression    = true
        recentFullMessages       = 3
        summaryThreshold         = 200
        requestTimeoutSeconds    = 300
        connectionTimeoutSeconds = 30
        stallTimeoutSeconds      = 300
        maxStallRetries          = 2
    }
}
