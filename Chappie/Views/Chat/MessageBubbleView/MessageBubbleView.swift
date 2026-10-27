// MessageBubbleView.swift
// Chappie
//
// WHY THIS FILE EXISTS:
// Renders individual chat message bubbles in the conversation scroll view.
//
// ATTACHMENTS STRATEGY:
// Each attachment is one row: icon + filename + file size.
// All files open via QuickLook on click — native preview + built-in Share button.
// File size is read from disk via localURL (no bytes stored in AttachedFile).
//
// TERMINAL CONFIRMATION (TERMINAL-CONFIRM):
// .terminalConfirmation case renders an inline Run/Cancel prompt.

import SwiftUI
import QuickLook


// MARK: - MessageBubbleView (public entry point)

struct MessageBubbleView: View {

    let msg: ChatMessage
    let availableWidth: CGFloat
    @Environment(ChappieViewModel.self) var viewModel

    var body: some View {
        switch msg {
        case .message(_, let isUser, let text, let cost, let attachments, _):
            messageBubble(isUser: isUser, text: text, cost: cost, attachments: attachments)

        case .terminalConfirmation(let id, let command, let threadId):
            terminalConfirmationBubble(id: id, command: command, threadId: threadId)

        case .toolCall:
            EmptyView()
        }
    }

    // MARK: - Bubble Render

    @ViewBuilder
    func messageBubble(
        isUser: Bool,
        text: String,
        cost: Double?,
        attachments: [AttachedFile]
    ) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isUser { Spacer() }

            if isUser {
                userBubble(text: text, attachments: attachments)
            } else {
                chappieBubble(text: text, cost: cost, attachments: attachments)
            }

            if !isUser { Spacer() }
        }
        .transition(
            .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .opacity
            )
        )
        .id(msg.id)
    }

    // MARK: - User Bubble

    @ViewBuilder
    func userBubble(text: String, attachments: [AttachedFile]) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !attachments.isEmpty {
                AttachmentListView(attachments: attachments, isUser: true)
            }
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.accentColor)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 12,
                bottomLeadingRadius: 12,
                bottomTrailingRadius: 4,
                topTrailingRadius: 12
            )
        )
    }

    // MARK: - Chappie Bubble

    @ViewBuilder
    func chappieBubble(text: String, cost: Double?, attachments: [AttachedFile]) -> some View {
        HStack {
            ZStack(alignment: .bottomTrailing) {
                VStack(alignment: .leading, spacing: 6) {
                    // Output file attachments shown above the text — they're the main result.
                    if !attachments.isEmpty {
                        AttachmentListView(attachments: attachments, isUser: false)
                    }
                    if !text.isEmpty {
                        MarkdownTextView(text: text, fontSize: 14)
                            .padding(.bottom, (cost ?? 0) > 0 ? 18 : 0)
                    }
                }

                if let cost = cost, cost > 0 {
                    Text(String(format: "🪙 %.2f ₽", cost))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 12,
                    bottomLeadingRadius: 4,
                    bottomTrailingRadius: 12,
                    topTrailingRadius: 12
                )
            )
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 12,
                    bottomLeadingRadius: 4,
                    bottomTrailingRadius: 12,
                    topTrailingRadius: 12
                )
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )

            Spacer()
        }
    }
}
