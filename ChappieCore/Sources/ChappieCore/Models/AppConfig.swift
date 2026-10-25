// AppConfig.swift
// ChappieCore
//
// Centralized application configuration — all magic numbers live here.
//
// DYNAMIC CONFIG (IT-02):
// AppConfig is created from thread settings, not a global singleton.
// Each thread gets its own config. AIOrchestrator.process() accepts config as a parameter.

import Foundation

/// Centralized application configuration. All tuning parameters live here.
///
/// DYNAMIC (IT-02): Created from ThreadSettings — each thread has its own config.
/// AppConfig.shared is the default (30 messages).
///
/// NO TOKEN BUDGET, NO STEP CAP: context depth is controlled only by message count.
/// Modern windows are ~1M tokens and task decomposition keeps runs far below that;
/// a fake "tokens = messages × 500" number and a 500-step cap were removed as misleading.
public struct AppConfig: Codable, Equatable, Sendable {

    // MARK: - Singleton

    /// Default config — used when thread has no custom settings.
    public static let shared = AppConfig()

    // MARK: - Parameters

    /// Hard limit on message count in context window. Range: 10...1000. Int.max when unlimited.
    public let maxMessagesInContext: Int

    /// When true — maxMessagesInContext is Int.max. No trimming.
    public let isUnlimitedContext: Bool

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

    /// Default config: 30 messages — matches ThreadSettings default.
    private init() {
        maxMessagesInContext     = 30
        isUnlimitedContext       = false
        requestTimeoutSeconds    = 300
        connectionTimeoutSeconds = 30
        stallTimeoutSeconds      = 300
        maxStallRetries          = 2
    }

    /// Creates config from thread settings.
    public init(settings: ThreadSettings) {
        isUnlimitedContext       = settings.isUnlimitedContext
        requestTimeoutSeconds    = 300
        connectionTimeoutSeconds = 30
        stallTimeoutSeconds      = 300
        maxStallRetries          = 2

        if settings.isUnlimitedContext {
            maxMessagesInContext = Int.max
        } else {
            // Clamp 10...1000 — mirrors ThreadSettings valid range
            maxMessagesInContext = max(10, min(1000, settings.maxMessagesInContext))
        }
    }

    /// Convenience init from raw message count — for tests and legacy code.
    public init(maxMessagesInContext: Int) {
        self.maxMessagesInContext = max(10, min(1000, maxMessagesInContext))
        isUnlimitedContext       = false
        requestTimeoutSeconds    = 300
        connectionTimeoutSeconds = 30
        stallTimeoutSeconds      = 300
        maxStallRetries          = 2
    }
}
