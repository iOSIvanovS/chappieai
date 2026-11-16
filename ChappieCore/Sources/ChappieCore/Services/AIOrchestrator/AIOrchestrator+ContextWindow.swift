import Foundation

extension AIOrchestrator {

    // MARK: - Context Window

    /// Builds the messages to send this turn, standing on the anchor remembered from last turn.
    ///
    /// THE ANCHOR IS THE WHOLE POINT. The caller passes the entire loaded history, which grows by
    /// a couple of messages every turn. Deciding only on its length gives a window that slides:
    /// 112 messages cut to the newest 30, next turn 114 cut to the newest 30 — the first message
    /// of the window moves forward and the prefix cache dies at its first byte. With an anchor the
    /// window starts at a fixed message and only its end moves, so the prefix is unchanged until
    /// the window genuinely outgrows its allowance.
    ///
    /// The anchor is a message signature, not an index: older history chunks are prepended on
    /// demand between turns, so every index moves. See WindowAnchor.
    func buildContextWindow(
        from history: [AIMessage],
        currentPrompt: String,
        currentMessage: AIMessage? = nil,
        config: AppConfig
    ) -> [AIMessage] {
        let maxMessages = config.maxMessagesInContext
        let warm = isCacheWarm()
        let mode = allowanceMode(isCacheWarm: warm)
        let storedAnchor = windowState.anchorSignature(threadId: currentThreadId)

        print("[AIOrchestrator] \(LogClock.stamp()) History: \(history.count) msgs"
              + " | Limit: \(maxMessages == Int.max ? "∞" : "\(maxMessages)")"
              + " | thread \(LogClock.short(currentThreadId))")

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

        let sliced = ContextWindowPolicy.slice(
            deduplicatedHistory,
            limit: maxMessages,
            mode: mode,
            anchorSignature: storedAnchor
        )

        if let trimmedFrom = sliced.trimmedFrom {
            print("[AIOrchestrator] \(LogClock.stamp()) Trimmed \(trimmedFrom) → \(sliced.messages.count) messages "
                  + "(limit \(maxMessages), allowance \(modeLabel(mode, limit: maxMessages)), "
                  + "cache \(warm ? "warm" : "cold") \(cacheAgeDescription()), "
                  + "anchor \(storedAnchor == nil ? "none" : "found"))")
        } else {
            // Nothing was cut, so this line is the only record of the window standing still —
            // which is exactly the case that must show `anchor found` and a stable prefix.
            print("[AIOrchestrator] \(LogClock.stamp()) Window kept: \(sliced.messages.count) of \(history.count) messages "
                  + "(limit \(maxMessages), allowance \(modeLabel(mode, limit: maxMessages)), "
                  + "cache \(warm ? "warm" : "cold") \(cacheAgeDescription()), "
                  + "anchor \(storedAnchor == nil ? "none" : "found"))")
        }

        // The anchor is remembered whether or not the cache was warm. A cold turn still sends its
        // window, and that request IS the new prefix: forgetting which message started it makes
        // the next turn cut to a different place and pay for the same prefix twice.
        // Measured 2026-11-16: a cold turn after a relaunch wrote 78824 tokens (21.43 RUB), and
        // because its anchor was discarded the turn after it wrote the whole prefix again instead
        // of reading it — 47k of the 79k rewritten for nothing.
        //
        // A stale anchor is harmless: `slice` ignores one that is no longer in the history and one
        // that sits so close to the end that it could not fill a window, and in any case never
        // lets the window shrink below `limit`.
        windowState.setAnchorSignature(sliced.anchor, threadId: currentThreadId)

        var contextWindow = sliced.messages
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
        windowState.lastRequestAt(threadId: threadId)
    }

    /// Records that a request is going out now, for the current thread.
    ///
    /// Called before each request of the agentic loop: that is when the provider writes or reads
    /// the prefix. Each step refreshes the mark, so a multi-step turn settles on its last step.
    func markRequestSent(now: Date = Date()) {
        windowState.setLastRequestAt(now, threadId: currentThreadId)
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

    /// The pause since the last request and the TTL it is measured against, for the log.
    ///
    /// A bare `warm`/`cold` word cannot be checked against anything: seeing "2m of 54m" next to it
    /// is what tells you the threshold did the right thing rather than happening to agree.
    func cacheAgeDescription(now: Date = Date()) -> String {
        guard let profile = aiClient.promptCacheProfile else { return "(route has no cache)" }
        let limit = Int((profile.ttl * ContextWindowPolicy.cacheWarmthMargin) / 60)
        guard let last = lastRequestAt(threadId: currentThreadId) else { return "(never used, ttl \(limit)m)" }
        let minutes = Int(now.timeIntervalSince(last) / 60)
        return "(\(minutes)m since last of \(limit)m)"
    }

    /// Rough token estimate: UTF-8 bytes / 4 * 1.5 overhead factor.
    func estimateTokens(_ message: AIMessage) -> Int {
        let text = message.contentString ?? ""
        return max(1, Int(Double(text.utf8.count) / 4.0 * 1.5))
    }
}
