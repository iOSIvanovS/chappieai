// RequestLog.swift
// ChappieCore
//
// Lightweight snapshot of what was sent to the AI before each request.
// Written synchronously before the network call — survives timeouts.
//
// WHY: on timeout, we cannot inspect the failed request body (stream was never returned).
// The log is the only post-mortem record. Used by DiagnosticRequest to explain what went wrong.

import Foundation

/// Metadata snapshot of one AI request, captured before the network call.
public struct RequestLog: Sendable {

    // MARK: - Fields

    /// Sequential index within the current orchestrator step (1 = first attempt, 2 = retry).
    public let attemptNumber: Int

    /// Number of messages in the context window sent to the model.
    public let messageCount: Int

    /// Rough token estimate for the full context (system + history + current turn).
    public let estimatedTokens: Int

    /// Number of tools available in this request.
    public let toolCount: Int

    /// File paths mentioned in the most recent tool call arguments, if any.
    /// Populated by AIOrchestrator from the last tool result in sessionHistory.
    public let recentFilePaths: [String]

    /// Wall-clock timestamp when the request was initiated.
    public let timestamp: Date

    // MARK: - Init

    public init(
        attemptNumber: Int,
        messageCount: Int,
        estimatedTokens: Int,
        toolCount: Int,
        recentFilePaths: [String]
    ) {
        self.attemptNumber = attemptNumber
        self.messageCount = messageCount
        self.estimatedTokens = estimatedTokens
        self.toolCount = toolCount
        self.recentFilePaths = recentFilePaths
        self.timestamp = Date()
    }

    // MARK: - Human-readable summary for diagnostic prompt

    /// Compact text description for injection into a diagnostic AI request.
    public var diagnosticSummary: String {
        var lines: [String] = []
        lines.append("- Attempt: \(attemptNumber) of 2")
        lines.append("- Messages in context: \(messageCount)")
        lines.append("- Estimated tokens: \(estimatedTokens)")
        lines.append("- Tools available: \(toolCount)")
        if !recentFilePaths.isEmpty {
            lines.append("- Recent file paths: \(recentFilePaths.joined(separator: ", "))")
        }
        lines.append("- Timestamp: \(ISO8601DateFormatter().string(from: timestamp))")
        return lines.joined(separator: "\n")
    }
}
