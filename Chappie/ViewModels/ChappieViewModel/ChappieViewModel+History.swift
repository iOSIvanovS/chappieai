// ChappieViewModel+History.swift
// Chappie
//
// Network history building for AI requests.

import SwiftUI
import ChappieCore

extension ChappieViewModel {

    // MARK: - Build Network History

    func buildRawNetworkHistory(excludingLast: Int = 0) -> [AIMessage] {
        let sourceMessages = excludingLast > 0 && messages.count > excludingLast
            ? Array(messages.dropLast(excludingLast))
            : messages

        return sourceMessages.compactMap { msg -> AIMessage? in
            guard case .message(_, let isUser, let text, _, let attachments) = msg else { return nil }

            let isSystemMessage = text.contains("Project connected")
                || text.contains("Memory cleared")
                || text.contains("API key updated")
                || text.hasPrefix("⚠️")
                || text.hasPrefix("Error:")
                || text.hasPrefix("Oops, error:")
            if isSystemMessage { return nil }

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
            if !attachments.isEmpty {
                var parts: [AIMultimodalPart] = []
                if !text.isEmpty { parts.append(.text(text)) }
                for attachment in attachments {
                    parts.append(multimodalPartSync(for: attachment))
                }
                return AIMessage(role: role, multimodalParts: parts)
            }

            return AIMessage(role: role, content: text)
        }
    }

    func buildCurrentAIMessage(text: String, attachments: [AttachedFile]) async -> AIMessage {
        guard !attachments.isEmpty else { return AIMessage(role: "user", content: text) }

        var parts: [AIMultimodalPart] = []
        if !text.isEmpty { parts.append(.text(text)) }
        for attachment in attachments {
            parts.append(contentsOf: await multimodalParts(for: attachment))
        }
        return AIMessage(role: "user", multimodalParts: parts)
    }
}
