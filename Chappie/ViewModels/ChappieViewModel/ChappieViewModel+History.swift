// ChappieViewModel+History.swift
// Chappie
//
// Network history building for AI requests.

import SwiftUI
import ChappieCore

extension ChappieViewModel {

    // MARK: - Build Network History

    /// Local notices that are shown in the chat but never sent to the model.
    private func isLocalNotice(_ text: String) -> Bool {
        Self.isLocalNoticeText(text)
    }

    /// Nonisolated so the storage layer can use it as a plain predicate off the main actor.
    private nonisolated static func isLocalNoticeText(_ text: String) -> Bool {
        text.contains("Project connected")
            || text.contains("Memory cleared")
            || text.contains("API key updated")
            || text.hasPrefix("⚠️")
            || text.hasPrefix("Error:")
            || text.hasPrefix("Oops, error:")
    }

    /// True for messages that end up in the model history (tool-call logs and local notices do not).
    private nonisolated static func isSentToModel(_ msg: ChatMessage) -> Bool {
        guard case .message(_, _, let text, _, _, _) = msg else { return false }
        return !isLocalNoticeText(text)
    }

    // MARK: - Context window vs. lazily loaded chunks

    /// The chat window only holds the newest storage chunk (500 messages), so right after a chunk
    /// rollover it may contain just a few messages and the model would lose its context.
    /// Prepends older chunks until the window holds enough messages for the context limit.
    /// The displayed part of the chat does not move: `displayedStart` shifts by the added count.
    func ensureModelHistoryLoaded() async {
        guard hasMoreChunks,
              let threadId = activeThread?.id,
              let store = threadStore,
              let oldest = oldestLoadedChunkIndex else { return }

        // Load enough for the widest allowance the policy can grant, not just the configured
        // window: on a cache-reading route up to 3x the limit is sent, and if only limit+1 were
        // loaded that allowance would never be reached — the context would snap back to the limit
        // right after every chunk rollover. Loading more is harmless; chunks are loaded on demand.
        // +1: the message being sent is in `messages` too.
        let needed = activeThreadSettings.maxMessagesInContext
            * ContextWindowPolicy.tripleMultiplier + 1

        guard let result = try? await store.loadOlderChunks(
            fromThreadId: threadId,
            currentOldestChunkIndex: oldest,
            alreadyEligible: messages.filter(Self.isSentToModel).count,
            needed: needed,
            as: ChatMessage.self,
            isEligible: Self.isSentToModel
        ), !result.messages.isEmpty else { return }

        // The user may have switched threads while chunks were loading — drop the result then.
        guard activeThread?.id == threadId, oldestLoadedChunkIndex == oldest else { return }

        messages = result.messages + messages
        displayedStart += result.messages.count
        hasMoreMessages = displayedStart > 0
        oldestLoadedChunkIndex = result.newOldestChunkIndex
        hasMoreChunks = result.hasMore
        print("[ChappieViewModel] Context window extended by \(result.messages.count) older messages (oldest chunk \(result.newOldestChunkIndex), hasMoreChunks=\(result.hasMore))")
    }

    /// Time labels for the user messages the model will see (current message included).
    /// Computed over the same filtered list as the history, so a gap is never measured
    /// across a message the model does not receive.
    func timestampLabels() -> [UUID: String] {
        let entries = messages.compactMap { msg -> MessageTimestampEntry? in
            guard case .message(let id, let isUser, let text, _, _, let createdAt) = msg,
                  !isLocalNotice(text) else { return nil }
            return MessageTimestampEntry(id: id, isUser: isUser, createdAt: createdAt)
        }
        return MessageTimestamp.labels(for: entries)
    }

    func buildRawNetworkHistory(excludingLast: Int = 0) -> [AIMessage] {
        let sourceMessages = excludingLast > 0 && messages.count > excludingLast
            ? Array(messages.dropLast(excludingLast))
            : messages
        let labels = timestampLabels()

        return sourceMessages.compactMap { msg -> AIMessage? in
            guard case .message(let id, let isUser, let text, _, let attachments, _) = msg else { return nil }

            if isLocalNotice(text) { return nil }

            let role = isUser ? "user" : "assistant"

            if !isUser {
                // AI messages: append attachment reference blocks so the model knows what files exist.
                // Actual bytes are never sent — AI uses fetch_attachment(uuid) to read on demand.
                if !attachments.isEmpty {
                    let refs = attachments.map { "[\(attachmentReferenceText(for: $0))]" }.joined(separator: "\n")
                    let combined = text.isEmpty ? refs : "\(text)\n\n\(refs)"
                    return AIMessage(role: role, content: combined)
                }
                return AIMessage(role: role, content: text)
            }

            // User messages: build multimodal content for images; text refs for everything else.
            // The time label is the first line of the text block; the stored text stays clean.
            let stamped = MessageTimestamp.prefixed(text, with: labels[id])
            if !attachments.isEmpty {
                var parts: [AIMultimodalPart] = []
                if !stamped.isEmpty { parts.append(.text(stamped)) }
                for attachment in attachments {
                    parts.append(multimodalPartSync(for: attachment))
                }
                return AIMessage(role: role, multimodalParts: parts)
            }

            return AIMessage(role: role, content: stamped)
        }
    }

    func buildCurrentAIMessage(text: String, attachments: [AttachedFile], timeLabel: String? = nil) async -> AIMessage {
        let stamped = MessageTimestamp.prefixed(text, with: timeLabel)
        guard !attachments.isEmpty else { return AIMessage(role: "user", content: stamped) }

        var parts: [AIMultimodalPart] = []
        if !stamped.isEmpty { parts.append(.text(stamped)) }
        for attachment in attachments {
            parts.append(contentsOf: await multimodalParts(for: attachment))
        }
        return AIMessage(role: "user", multimodalParts: parts)
    }
}
