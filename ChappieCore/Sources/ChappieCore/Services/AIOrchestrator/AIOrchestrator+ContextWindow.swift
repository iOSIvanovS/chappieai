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
        let mode = allowanceMode(isCacheWarm: isCacheWarm())

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
                  + "(limit \(maxMessages), allowance \(modeLabel(mode, limit: maxMessages)))")
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

    // MARK: - Cache Warmth

    /// When the last request of this thread was sent, or nil before the first one.
    ///
    /// Deliberately in memory only: losing it costs one extra cache write after a restart, while
    /// persisting it would mean a database write on every single request of the agentic loop.
    var lastRequestAt: Date? {
        get { lastRequestAtStorage }
        set { lastRequestAtStorage = newValue }
    }

    /// The prefix is gone once a pause outlasts the cache TTL, and cannot be relied on in the
    /// last few percent before expiry either — a request in flight from another turn may have
    /// refreshed it, but the safe assumption is that it expired.
    func isCacheWarm(now: Date = Date()) -> Bool {
        guard let profile = aiClient.promptCacheProfile, let last = lastRequestAt else { return false }
        return now.timeIntervalSince(last) < profile.ttl * Self.cacheWarmthMargin
    }

    /// A safety margin below the nominal TTL, so a request that starts just before expiry does not
    /// assume a prefix that another turn's write may have pushed past it.
    static let cacheWarmthMargin: Double = 0.9

    /// Rough token estimate: UTF-8 bytes / 4 * 1.5 overhead factor.
    func estimateTokens(_ message: AIMessage) -> Int {
        let text = message.contentString ?? ""
        return max(1, Int(Double(text.utf8.count) / 4.0 * 1.5))
    }
}
