import Foundation

extension AIOrchestrator {

    // MARK: - Retry Wrapper

    /// Sends one model request, re-sending it on transient failures (HTTP 5xx/429, network drops,
    /// timeouts, stalls, streams cut mid-answer). The whole policy lives in LLMRetryRunner.
    func streamWithRetry(
        systemPrompt: String,
        sessionHistory: [AIMessage],
        tools: [AITool],
        config: AppConfig,
        onToken: (@Sendable (String) -> Void)?,
        onRetry: (@Sendable (RetryStatus?) -> Void)? = nil
    ) async throws -> AIStreamResult {

        let client = aiClient
        let stallTimeout = config.stallTimeoutSeconds

        var runner = LLMRetryRunner(policy: retryPolicy)
        runner.slowFailureLimit = config.maxStallRetries
        runner.contextHint = "Context: \(sessionHistory.count) messages, ~\(sessionHistory.reduce(0) { $0 + estimateTokens($1) }) tokens."
        runner.shouldAbort = { [weak self] in await self?.isInvalidated ?? true }

        return try await runner.run(history: sessionHistory, onRetry: onRetry) { history in
            try await client.streamRequestWithTools(
                systemPrompt: systemPrompt,
                chatHistory: ImageValve.apply(history),
                tools: tools,
                stallTimeout: stallTimeout,
                onToken: onToken
            )
        }
    }

}
