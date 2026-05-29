// AppConfig.swift
// ChappieCore
//
// Centralized application configuration.
//
// CHANGE HISTORY:
// - IT-02 (REFACTOR-THREADS): AppConfig became dynamic.
//   Added public init(maxMessagesInContext:) to create config from thread settings.
//   tokenBudget is now computed automatically: maxMessagesInContext × 500.
//   AppConfig.shared remains as the default config (20 messages = 10,000 tokens).
//
// - tokenBudget: 30,000 → 12,000 → 6,000 → dynamic (maxMessages × 500)
//   Reason for last reduction: estimateTokens() formula was wrong (chars/4 instead of
//   UTF8bytes/4×1.5). After fixing the formula, real budget was ~2x less than expected.
//   6,000 in new units ≈ ~10,000-12,000 real tokens — that was our target.
//
// - recentFullMessages: 6 → 3 (last 3 exchanges = current task, sufficient)
//
// - summaryThreshold: 800 → 400 → 200
//   Reason: more aggressive summarization. 200 units ≈ ~500-600 real tokens.
//   Messages shorter than this are short replies, not worth summarizing.
//
// - maxMessagesInContext: added as hard limit on top of token budget.
//   Reason: tokenBudget allowed 30+ short summary-messages, but the model needs
//   semantic context, not a long chain of short replies.
//   12 → 20 (thread default): 20 messages × 500 = 10,000 tokens — reasonable balance.
//
// - Range extended: 10...100 → 10...1000
//   isUnlimitedContext flag added: when true, all limits are set to Int.max.
//
// - stallTimeoutSeconds added (STALL-WATCHDOG):
//   60-second silence detector for streaming. If no tokens arrive for 60s mid-stream,
//   the stream is cancelled and AIOrchestrator retries with a continuation prompt.
//
// - stallTimeoutSeconds: 60 → 180 (3 minutes)
//   Reason: claude-sonnet-4.6 with large context (40+ messages) can silently "think"
//   for 60+ seconds before emitting the first token. 60s was too aggressive and caused
//   false stall detections. 180s is safe even for the slowest reasoning passes.

import Foundation

/// Centralized application configuration.
///
/// PRINCIPLE: All "magic numbers" live here, not scattered through the code.
/// This is the single place to change parameters when tuning performance.
///
/// ARCHITECTURAL DECISION (IT-02):
/// AppConfig is now DYNAMIC — created from thread settings.
/// Each thread has its own AppConfig with the required context depth.
/// AIOrchestrator.process() accepts config as a parameter (default: AppConfig.shared).
/// This allows different threads to have different parameters without a global singleton.
public struct AppConfig: Codable, Equatable, Sendable {

    // MARK: - Singleton (default config)

    /// Global default config — used when a thread has no custom settings.
    ///
    /// DEFAULT: 20 messages = 10,000 tokens.
    /// Reasonable balance between context depth and request cost.
    public static let shared = AppConfig()

    // MARK: - Parameters

    /// Maximum number of orchestrator steps in one reasoning loop.
    ///
    /// Guards against infinite loops if the model gets stuck on tools.
    /// Hardcoded — user should not change this.
    public let maxOrchestratorSteps: Int

    /// Maximum token budget for history sent to the LLM.
    ///
    /// FORMULA (IT-02): tokenBudget = maxMessagesInContext × 500
    /// UNLIMITED: Int.max when isUnlimitedContext = true — no trimming at all.
    ///
    /// UNITS (important!):
    /// Measured in units of estimateTokens():
    ///   estimateTokens = UTF8bytes / 4 × 1.5
    ///
    /// RANGE:
    /// 10 messages → 5,000 tokens (minimum)
    /// 20 messages → 10,000 tokens (default)
    /// 100 messages → 50,000 tokens
    /// 1000 messages → 500,000 tokens (maximum)
    /// Int.max → unlimited (no trimming)
    ///
    /// System prompt (~3,000 tokens) is NOT included — it is cached separately.
    public let tokenBudget: Int

    /// Hard limit on the number of messages in the context window.
    ///
    /// WHY SEPARATE FROM tokenBudget:
    /// tokenBudget controls total token volume, not message count.
    /// If history has 30+ short summary-messages (~50-100 tokens each),
    /// they all fit in budget but create a useless long chain.
    /// The model needs semantic context, not 30 short replies.
    ///
    /// RANGE: 10...1000
    /// DEFAULT: 20 (reasonable balance for most tasks)
    /// UNLIMITED: Int.max when isUnlimitedContext = true
    public let maxMessagesInContext: Int

    /// When true — no context trimming is applied. All messages are sent as-is.
    /// Both tokenBudget and maxMessagesInContext are set to Int.max.
    public let isUnlimitedContext: Bool

    /// Number of most recent messages always sent FULLY (without summary replacement).
    ///
    /// WHY 3:
    /// 3 last exchanges = user set a task + Chappie started doing it + current step.
    /// Sufficient for conversational continuity. Hardcoded — technical parameter.
    public let recentFullMessages: Int

    /// Minimum message size in estimateTokens() units for summarization.
    ///
    /// WHY 200:
    /// 200 units × (4/1.5) ≈ 533 UTF-8 bytes ≈ ~130-260 chars (language-dependent).
    /// Roughly 2-3 lines of text. Messages shorter than this are short replies —
    /// summarizing them is pointless (summary would be longer than the original).
    /// Hardcoded — technical parameter.
    public let summaryThreshold: Int

    /// API response timeout in seconds.
    ///
    /// WHY 300 SECONDS (5 minutes):
    /// Default URLSession timeout is 60 seconds — catastrophically low for Chappie,
    /// which may execute dozens of tool calls in one reasoning loop.
    /// Complex tasks — project inspection, multi-file refactoring — take 2-4 minutes.
    public let requestTimeoutSeconds: TimeInterval

    /// Connection establishment timeout in seconds.
    ///
    /// WHY 30 SECONDS:
    /// If connection is not established in 30 seconds — clear network issue.
    public let connectionTimeoutSeconds: TimeInterval

    /// Stall timeout for streaming in seconds (STALL-WATCHDOG).
    ///
    /// WHY 180 SECONDS (3 minutes):
    /// AI models can "think" for 60+ seconds between tokens during complex reasoning,
    /// especially claude-sonnet-4.6 with large context (40+ messages).
    /// 60s was too aggressive — caused false stall detections on legitimate slow responses.
    /// 180s is safe even for the slowest reasoning passes while still catching real stalls.
    ///
    /// When stall is detected:
    /// 1. The stream is cancelled via Task cancellation.
    /// 2. AIOrchestrator retries with a continuation prompt (up to maxStallRetries times).
    /// 3. The partial response is preserved and the model is asked to continue from there.
    public let stallTimeoutSeconds: TimeInterval

    /// Maximum number of stall-triggered retries per orchestrator step (STALL-WATCHDOG).
    ///
    /// WHY 2:
    /// One retry is usually enough. Two retries handle transient network hiccups.
    /// After 2 retries we give up and throw an error — infinite retry loops are worse
    /// than a clear error message.
    public let maxStallRetries: Int

    // MARK: - Initialization

    /// Creates the default config (20 messages, 10,000 tokens).
    ///
    /// Used for AppConfig.shared and as default in AIOrchestrator.process().
    private init() {
        self.maxOrchestratorSteps    = 100
        self.maxMessagesInContext    = 20
        self.tokenBudget             = 20 * 500
        self.isUnlimitedContext      = false
        self.recentFullMessages      = 3
        self.summaryThreshold        = 200
        self.requestTimeoutSeconds   = 300
        self.connectionTimeoutSeconds = 30
        self.stallTimeoutSeconds     = 180
        self.maxStallRetries         = 2
    }

    /// Creates a config from thread settings.
    ///
    /// ARCHITECTURAL DECISION (IT-02):
    /// Instead of a global singleton — config is created from specific thread settings.
    /// tokenBudget is computed automatically by formula maxMessagesInContext × 500.
    /// Other technical parameters are hardcoded — user does not see them.
    ///
    /// UNLIMITED MODE:
    /// When settings.isUnlimitedContext = true, both maxMessagesInContext and tokenBudget
    /// are set to Int.max. The orchestrator's buildContextWindow() skips all trimming.
    ///
    /// - Parameter settings: Thread settings with context depth and unlimited flag.
    public init(settings: ThreadSettings) {
        self.maxOrchestratorSteps    = 100
        self.isUnlimitedContext      = settings.isUnlimitedContext
        self.recentFullMessages      = 3
        self.summaryThreshold        = 200
        self.requestTimeoutSeconds   = 300
        self.connectionTimeoutSeconds = 30
        self.stallTimeoutSeconds     = 180
        self.maxStallRetries         = 2

        if settings.isUnlimitedContext {
            // No trimming — send everything to the model
            self.maxMessagesInContext = Int.max
            self.tokenBudget          = Int.max
        } else {
            // Clamp to valid range — guard against corrupted JSON values
            let clamped = max(10, min(1000, settings.maxMessagesInContext))
            self.maxMessagesInContext = clamped
            // FORMULA: each message "costs" 500 token budget units.
            // Ensures linear relationship between user setting and real budget.
            self.tokenBudget          = clamped * 500
        }
    }

    /// Convenience init from raw message count (used in tests and legacy code).
    ///
    /// - Parameter maxMessagesInContext: Context depth (10...1000). Clamped automatically.
    public init(maxMessagesInContext: Int) {
        let clamped = max(10, min(1000, maxMessagesInContext))
        self.maxOrchestratorSteps    = 100
        self.maxMessagesInContext    = clamped
        self.tokenBudget             = clamped * 500
        self.isUnlimitedContext      = false
        self.recentFullMessages      = 3
        self.summaryThreshold        = 200
        self.requestTimeoutSeconds   = 300
        self.connectionTimeoutSeconds = 30
        self.stallTimeoutSeconds     = 180
        self.maxStallRetries         = 2
    }
}
