// ChatScrollView.swift
// Chappie
//
// WHY THIS FILE EXISTS:
// Scroll logic (auto-scroll on new messages, thinking indicator) was embedded
// directly in ContentView's body. This component owns all message list rendering.
//
// BOTTOM PADDING:
// Accepts `bottomPadding` from ContentView — the real rendered height of InputMorphView.
// This prevents the last message from being hidden under the input panel on launch,
// when the editor grows, or when the panel morphs between states.
// Auto-scroll fires on bottomPadding change so the view stays pinned to the bottom.

import SwiftUI

/// Scrollable message list with auto-scroll and thinking indicator.
///
/// IMPORTANT: Accepts `visibleMessages` — already filtered list (only .message, max 30).
/// Filtering happens in ViewModel, not here.
struct ChatScrollView: View {

    /// Filtered message list (only .message, max 30)
    let messages: [ChatMessage]

    /// Flag: Chappie is thinking (show spinner or streaming bubble)
    let isThinking: Bool

    /// Accumulated streaming response text.
    ///
    /// Empty → show spinner (Chappie is calling tools).
    /// Non-empty → show live streaming bubble.
    /// After streaming ends ViewModel resets this to "" and appends .message to history.
    let streamingText: String

    /// Cumulative cost of the current request — running total.
    ///
    /// Updated after each internal orchestrator API call.
    /// Displayed in the bottom-right corner of the streaming bubble.
    let runningCost: Double

    /// Height of InputMorphView reported by ContentView.
    ///
    /// Used as bottom padding so the last message stays visible above the input panel.
    /// Auto-scroll fires whenever this changes (panel grows/shrinks).
    let bottomPadding: CGFloat

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {

                    // Welcome screen — shown only when chat is empty
                    if messages.isEmpty && !isThinking {
                        welcomeMessage
                            .transition(.opacity)
                    } else {
                        // ForEach works with at most 30 items
                        ForEach(messages) { msg in
                            MessageBubbleView(msg: msg)
                        }
                    }

                    // STREAMING BLOCK:
                    // 1. isThinking == false → nothing
                    // 2. isThinking == true, streamingText == "" → spinner
                    // 3. isThinking == true, streamingText != "" → live bubble
                    if isThinking {
                        if streamingText.isEmpty {
                            thinkingIndicator
                                .transition(.opacity)
                                .id("thinking-spinner")
                        } else {
                            streamingBubble
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity
                                ))
                                .id("thinking-streaming")
                        }
                    }

                    // Invisible anchor at the very bottom of the list
                    Spacer(minLength: 0)
                        .id("BottomSpacer")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                // Bottom padding = input panel height so the last message is never hidden under it
                .padding(.bottom, max(bottomPadding, 12))
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: messages)
                .animation(.easeInOut(duration: 0.25), value: isThinking)
                .animation(.easeInOut(duration: 0.3), value: streamingText.isEmpty)
            }
            .onAppear {
                // Scroll to bottom on appear — InputMorphView may not be laid out yet,
                // so we fire a second scroll after a short delay to catch the final position.
                proxy.scrollTo("BottomSpacer", anchor: .bottom)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("BottomSpacer", anchor: .bottom)
                    }
                }
            }
            .onChange(of: messages) { _, _ in
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo("BottomSpacer", anchor: .bottom)
                }
            }
            .onChange(of: isThinking) { _, isThinking in
                if isThinking {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo("BottomSpacer", anchor: .bottom)
                    }
                }
            }
            .onChange(of: streamingText) { _, _ in
                proxy.scrollTo("BottomSpacer", anchor: .bottom)
            }
            // When the input panel grows or shrinks — re-pin to bottom immediately
            .onChange(of: bottomPadding) { _, _ in
                proxy.scrollTo("BottomSpacer", anchor: .bottom)
            }
        }
    }

    // MARK: - Subviews

    /// Welcome message for empty chat.
    ///
    /// Design: neutral left-aligned bubble — like Chappie's first message.
    /// Uses the same styling as Chappie's bubble in MessageBubbleView.
    private var welcomeMessage: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Привет! Я — Чаппи 👋")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Выбери папку проекта в сайдбаре и скажи, что нужно сделать.")
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(.secondary)
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

            Spacer(minLength: 40)
        }
    }

    /// Spinner — shown while Chappie is thinking or calling tools.
    ///
    /// Minimal: just a ProgressView in a left-aligned bubble.
    /// Current tool call is shown in InputMorphView below.
    private var thinkingIndicator: some View {
        HStack {
            ProgressView()
                .controlSize(.small)
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

            Spacer(minLength: 40)
        }
    }

    /// Live bubble with growing streaming response text.
    ///
    /// WHY MarkdownTextView NOT Text:
    /// Chappie may start writing a code block mid-stream.
    /// MarkdownTextView handles unclosed blocks gracefully —
    /// an unclosed ``` renders as plain text until closed.
    ///
    /// WHY .contentTransition(.interpolate):
    /// Each token causes SwiftUI to redraw the View with a new string.
    /// .interpolate smoothly animates the change between frames — "typing" effect.
    ///
    /// COST IN BOTTOM-RIGHT CORNER:
    /// ZStack alignment: .bottomTrailing pins the cost label over content.
    /// Shown from the start (0.00 ₽) and grows with each API call.
    /// .contentTransition(.numericText) animates digit rolling.
    private var streamingBubble: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {

                // Main bubble content: text + blinking cursor
                HStack(alignment: .bottom, spacing: 0) {
                    MarkdownTextView(text: streamingText, fontSize: 14)
                        .contentTransition(.interpolate)
                        .animation(.linear(duration: 0.08), value: streamingText)

                    // Blinking cursor — visual indicator that text is still being written
                    BlinkingCursor()
                        .padding(.bottom, 1)
                }
                // Bottom padding so the cost label doesn't overlap the last line
                .padding(.bottom, 18)

                // RUNNING COST — bottom-right corner of the bubble
                Text(String(format: "🪙 %.2f ₽", runningCost))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText(value: runningCost))
                    .animation(.easeInOut(duration: 0.3), value: runningCost)
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

            Spacer(minLength: 40)
        }
    }
}

// MARK: - BlinkingCursor

/// Blinking cursor for the streaming bubble.
///
/// Extracted into its own View so the animation is isolated and doesn't
/// trigger a full bubble redraw on every new token.
private struct BlinkingCursor: View {
    @State private var isVisible = true

    var body: some View {
        Text("▍")
            .font(.system(size: 14))
            .foregroundStyle(Color.accentColor)
            .opacity(isVisible ? 1 : 0)
            .animation(
                .easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                value: isVisible
            )
            .onAppear {
                isVisible = false
            }
    }
}

// MARK: - Preview

#Preview("With history and streaming") {
    ChatScrollView(
        messages: [
            .message(isUser: true, text: "Show me a code example"),
            .message(
                isUser: false,
                text: "Sure! Here's an example:\n\n```swift\n// Example ViewModel\n@Observable\nfinal class ViewModel {\n    var count = 0\n}\n```\n\nUse **@Observable** for automatic tracking.",
                cost: 0.42
            ),
        ],
        isThinking: true,
        streamingText: "Also you can add `@MainActor` for **thread safety**...",
        runningCost: 1.23,
        bottomPadding: 80
    )
    .frame(width: 650, height: 500)
    .background(Color(NSColor.windowBackgroundColor))
}

#Preview("Spinner (tools)") {
    ChatScrollView(
        messages: [
            .message(isUser: true, text: "Analyse the project"),
        ],
        isThinking: true,
        streamingText: "",
        runningCost: 0.0,
        bottomPadding: 60
    )
    .frame(width: 650, height: 300)
    .background(Color(NSColor.windowBackgroundColor))
}

#Preview("Empty chat") {
    ChatScrollView(
        messages: [],
        isThinking: false,
        streamingText: "",
        runningCost: 0.0,
        bottomPadding: 60
    )
    .frame(width: 650, height: 300)
    .background(Color(NSColor.windowBackgroundColor))
}
