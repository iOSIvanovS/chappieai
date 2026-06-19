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

        let cappedHistory = (maxMessages != Int.max && deduplicatedHistory.count > maxMessages)
            ? Array(deduplicatedHistory.suffix(maxMessages))
            : deduplicatedHistory

        var contextWindow = cappedHistory
        if let message = currentMessage {
            contextWindow.append(message)
        } else {
            contextWindow.append(AIMessage(role: "user", content: currentPrompt))
        }

        print("[AIOrchestrator] Sending: \(contextWindow.count) msgs")
        return contextWindow
    }

    /// Rough token estimate: UTF-8 bytes / 4 * 1.5 overhead factor.
    func estimateTokens(_ message: AIMessage) -> Int {
        let text = message.contentString ?? ""
        return max(1, Int(Double(text.utf8.count) / 4.0 * 1.5))
    }
}
