import Foundation

extension AIOrchestrator {

    // MARK: - Retry Wrapper

    /// Sends one model request, re-sending it on transient failures (HTTP 5xx/429, network drops,
    /// timeouts, stalls, streams cut mid-answer). The whole policy lives in LLMRetryRunner.
    func streamWithRetry(
        systemPrompt: String,
        sessionHistory: [AIMessage],
        tools: [AITool],
        screenFrame: [AIMultimodalPart]? = nil,
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
            // The live screen goes LAST, after the whole history and therefore after the cache
            // breakpoint. It changes on every computer-use step; inside the prefix it would force
            // a rewrite of everything from that point on, every single step. See ScreenFrame.
            // The history itself is never edited — an append-only prefix is what a cache is.
            var requestHistory = ImageValve.apply(history)
            if let screenFrame {
                requestHistory.append(ScreenFrame.message(parts: screenFrame))
            }
            return try await client.streamRequestWithTools(
                systemPrompt: systemPrompt,
                chatHistory: requestHistory,
                tools: tools,
                stallTimeout: stallTimeout,
                onToken: onToken
            )
        }
    }

}
