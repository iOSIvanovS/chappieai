// MessageBubbleView.swift
// Chappie
//
// WHY THIS FILE EXISTS:
// Formerly MessageBubble was a private struct inside ContentView.swift.
// Extracted to a separate file to:
//   1. Keep ContentView from becoming a monolith
//   2. Allow reuse (e.g. in search or preview)
//   3. Isolate the visual bubble logic so it's easy to change
//
// CHANGE (Stage 6 — ТД-6):
// MessageBubbleView now takes a typed enum ChatMessage instead of a struct.
//
// CHANGE (ТД-UX-PERF — UI performance optimization):
// .toolCall is completely removed from this component's render.
// .toolCall entries no longer appear in the feed — they are shown in StatusBarView.
// MessageBubbleView now renders ONLY .message (text messages).
//
// CHANGE (ТД-COST-SUMMARY — Self-Summary):
// .message case gained a 5th field `summary: String?`.
// Destructuring pattern updated — `_` added for summary.
//
// CHANGE (UX-ANIMATION — Smooth bubble appearance):
// Added .transition on the bubble: new messages smoothly slide in from the bottom
// with simultaneous fade-in.
//
// CHANGE (UX-TYPOGRAPHY — Typography and Markdown):
// Chappie's bubble now uses MarkdownTextView instead of Text():
//   - Code blocks in Xcode Intelligence Panel style (dark background, Swift highlighting)
//   - Inline code, bold, italic, headings
//   - SF Pro Text 14pt, lineSpacing 5 (Apple HIG: 1.3–1.5× line-height)
//   - Copy button in code blocks
//
// CHANGE (UX-COST-IN-BUBBLE — Cost inside bubble):
// Cost moved from below the bubble INTO it — bottom-trailing corner.
// Uses ZStack(alignment: .bottomTrailing) + padding(.bottom, 18) under the text.
// Shown only for Chappie messages (isUser == false) with known cost.
// Standard messenger UX pattern (WhatsApp, Telegram) — time/status inside.
//
// CHANGE (MULTIMODAL):
// .message case gained a 6th field `attachments: [AttachedFile]`.
// Destructuring pattern updated — `_` added for attachments.
// Attachment rendering (image thumbnails, file chips) will be added in Step 4.
//
// BUBBLE DESIGN (Apple HIG + macOS 26):
// User: accent color (blue), white text — "our" messages
// Chappie: clean background with thin border, like macOS 26 cards — neutral
// Both bubbles: cornerRadius 12, shadow 0.1 opacity — light, not aggressive

import SwiftUI

/// Visual representation of a text message in the chat history.
///
/// Renders only `.message` — a bubble with text from the user or from Chappie.
/// Chappie's bubble uses MarkdownTextView for code and formatting support.
/// User's bubble uses plain Text — users don't write markdown.
struct MessageBubbleView: View {

    let msg: ChatMessage

    var body: some View {
        // Render only .message. .toolCall entries don't reach this component.
        // IMPORTANT: pattern destructures ALL 6 fields of the .message case:
        //   id, isUser, text, cost, summary, attachments
        // summary and attachments are ignored via `_` — not shown in this view yet.
        if case .message(_, let isUser, let text, let cost, _, _) = msg {
            messageBubble(isUser: isUser, text: text, cost: cost)
                // APPEARANCE ANIMATION:
                // .asymmetric: insertion — slide from bottom + fade, removal — fade only.
                // Standard messenger UX pattern (iMessage, Telegram).
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    )
                )
        }
    }

    // MARK: - Bubble Render

    /// Text message bubble.
    ///
    /// User — right-aligned, accent color, white text, plain Text.
    /// Chappie — left-aligned, neutral background with border, MarkdownTextView with code support.
    @ViewBuilder
    private func messageBubble(isUser: Bool, text: String, cost: Double?) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Push user messages to the right via leading Spacer
            if isUser { Spacer(minLength: 40) }

            if isUser {
                // USER BUBBLE:
                // Plain Text — users don't write markdown.
                // White text on accent background.
                // Cost is not shown for user messages —
                // cost belongs to Chappie's response, not the question.
                Text(text)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor)
                    .clipShape(
                        // Rounded corners: all 12pt except bottom-trailing — 4pt.
                        // This iMessage trick creates a bubble "tail" without extra graphics.
                        UnevenRoundedRectangle(
                            topLeadingRadius: 12,
                            bottomLeadingRadius: 12,
                            bottomTrailingRadius: 4,
                            topTrailingRadius: 12
                        )
                    )
            } else {
                // CHAPPIE BUBBLE:
                // ZStack lets us overlay cost in the bottom-trailing corner.
                // Standard messenger pattern (WhatsApp, Telegram) — message metadata
                // (time, status, price) lives inside the bubble.
                ZStack(alignment: .bottomTrailing) {

                    // Main content: MarkdownTextView with code and formatting support.
                    MarkdownTextView(text: text, fontSize: 14)
                        // Bottom padding reserves space for the cost line,
                        // so it doesn't overlap the last line of text.
                        // Padding only applied when cost is present.
                        .padding(.bottom, cost != nil ? 18 : 0)

                    // REQUEST COST — bottom-trailing corner of the bubble.
                    // Shown only for Chappie messages with known cost.
                    // Tertiary foreground — unobtrusive color, doesn't distract from text.
                    if let cost = cost {
                        Text(String(format: "🪙 %.2f ₽", cost))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    // Adaptive background: white in Light mode, dark grey in Dark mode.
                    // textBackgroundColor — Apple standard for "surface".
                    Color(NSColor.textBackgroundColor)
                )
                .clipShape(
                    // Mirror variant: bottom-leading corner — 4pt ("tail" on the left).
                    UnevenRoundedRectangle(
                        topLeadingRadius: 12,
                        bottomLeadingRadius: 4,
                        bottomTrailingRadius: 12,
                        topTrailingRadius: 12
                    )
                )
                .overlay(
                    // Thin border — separates bubble from window background.
                    // Especially important in Light mode where bubble bg is close to window bg.
                    UnevenRoundedRectangle(
                        topLeadingRadius: 12,
                        bottomLeadingRadius: 4,
                        bottomTrailingRadius: 12,
                        topTrailingRadius: 12
                    )
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }

            // Push Chappie messages to the left via trailing Spacer
            if !isUser { Spacer(minLength: 40) }
        }
        // Use message id as anchor for ScrollViewReader.scrollTo()
        .id(msg.id)
    }
}

// MARK: - Preview

#Preview("Messages") {
    ScrollView {
        VStack(spacing: 16) {
            MessageBubbleView(msg: .message(isUser: true, text: "Hey Chappie! How's it going?"))

            MessageBubbleView(msg: .message(
                isUser: false,
                text: "Hey! 🚀 All good.\n\nHere's a code example:\n\n```swift\n// Streaming response\nfunc streamResponse() async {\n    for await token in stream {\n        await MainActor.run {\n            streamingText += token\n        }\n    }\n}\n```\n\nUse **async/await** for working with streams.",
                cost: 1.23
            ))

            MessageBubbleView(msg: .message(
                isUser: true,
                text: "Got it, thanks! What about `@Observable`?"
            ))

            MessageBubbleView(msg: .message(
                isUser: false,
                text: "## @Observable\n\n`@Observable` is a Swift 5.9 macro that replaces `ObservableObject`.\n\n**Advantages:**\n- No `@Published` — all properties are tracked automatically\n- Works with `@State` in Views\n- Full Swift 6 compatibility\n\n```swift\n@Observable\nfinal class ViewModel {\n    var count: Int = 0  // tracked automatically\n}\n```",
                cost: 0.87
            ))
        }
        .padding()
    }
    .frame(width: 650, height: 700)
    .background(Color(NSColor.windowBackgroundColor))
}
