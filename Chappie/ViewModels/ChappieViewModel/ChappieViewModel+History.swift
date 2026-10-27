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
        text.contains("Project connected")
            || text.contains("Memory cleared")
            || text.contains("API key updated")
            || text.hasPrefix("⚠️")
            || text.hasPrefix("Error:")
            || text.hasPrefix("Oops, error:")
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
