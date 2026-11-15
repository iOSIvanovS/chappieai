import Foundation

extension AIOrchestrator {

    // MARK: - Context Window

    func buildContextWindow(
        from history: [AIMessage],
        currentPrompt: String,
        currentMessage: AIMessage? = nil,
        config: AppConfig
    ) -> [AIMessage] {
        let maxMessages = config.maxMessagesInContext
        let warm = isCacheWarm()
        let mode = allowanceMode(isCacheWarm: warm)

        print("[AIOrchestrator] History: \(history.count) msgs | Limit: \(maxMessages == Int.max ? "∞" : "\(maxMessages)")")

        // Deduplicate: if the last history message is the same as currentPrompt, drop it.
        // Prevents double-sending the user message when history already includes it.
        let deduplicatedHistory: [AIMessage]
        if let lastMessage = history.last,
           lastMessage.role == "user",
           let lastContent = lastMessage.contentString,
           lastContent == currentPrompt {
            deduplicatedHistory = Array(history.dropLast())
        } else {
            deduplicatedHistory = history
        }

        let (cappedHistory, trimmedFrom) = ContextWindowPolicy.trim(
            deduplicatedHistory,
            limit: maxMessages,
            mode: mode
        )
        if let trimmedFrom {
            print("[AIOrchestrator] Trimmed \(trimmedFrom) → \(cappedHistory.count) messages "
                  + "(limit \(maxMessages), allowance \(modeLabel(mode, limit: maxMessages)), "
                  + "cache \(warm ? "warm" : "cold"))")
        }

        var contextWindow = cappedHistory
        if let message = currentMessage {
            contextWindow.append(message)
        } else {
            contextWindow.append(AIMessage(role: "user", content: currentPrompt))
        }

        print("[AIOrchestrator] Sending: \(contextWindow.count) msgs")
        return contextWindow
    }

    // MARK: - Cache Warmth

    /// Chooses how much room beyond the window this turn may use.
    ///
    /// A cache-reading route gets three times the window, but only while the cache is warm: after
    /// a pause longer than the cache TTL the old prefix is gone, so keeping the history long
    /// protects nothing and only makes the next write bigger. Everything else gets the small
    /// measured slack, which is what this code did before the native route existed.
    func allowanceMode(isCacheWarm: Bool) -> ContextWindowAllowance {
        guard aiClient.promptCacheProfile != nil else { return .slack }
        return isCacheWarm ? .triple : .exact
    }

    func modeLabel(_ mode: ContextWindowAllowance, limit: Int) -> String {
        switch mode {
        case .exact:  return "exact"
        case .slack:  return "slack \(ContextWindowPolicy.slack(for: limit))"
        case .triple: return "x\(ContextWindowPolicy.tripleMultiplier)"
        }
    }

    // MARK: - Request Time

    /// When the last request of this thread was sent, or nil before the first one.
    ///
    /// Read from the store rather than held in the actor: the mark must survive an app relaunch,
    /// otherwise the first turn after every restart rewrites the whole prefix (measured: 84079
    /// tokens, 23.64 RUB, against 2.29 RUB for a read).
    func lastRequestAt(threadId: UUID?) -> Date? {
        cacheWarmth.lastRequestAt(threadId: threadId)
    }

    /// Records that a request is going out now, for the current thread.
    ///
    /// Called before each request of the agentic loop: that is when the provider writes or reads
    /// the prefix. Each step refreshes the mark, so a multi-step turn settles on its last step.
    func markRequestSent(now: Date = Date()) {
        cacheWarmth.setLastRequestAt(now, threadId: currentThreadId)
    }

    /// The prefix is gone once a pause outlasts the cache TTL, and cannot be relied on in the
    /// last few percent before expiry either — a request in flight from another turn may have
    /// refreshed it, but the safe assumption is that it expired.
    func isCacheWarm(now: Date = Date()) -> Bool {
        ContextWindowPolicy.cacheIsWarm(
            lastRequestAt: lastRequestAt(threadId: currentThreadId),
            now: now,
            profile: aiClient.promptCacheProfile
        )
    }

    /// Rough token estimate: UTF-8 bytes / 4 * 1.5 overhead factor.
    func estimateTokens(_ message: AIMessage) -> Int {
        let text = message.contentString ?? ""
        return max(1, Int(Double(text.utf8.count) / 4.0 * 1.5))
    }
}
