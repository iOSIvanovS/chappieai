// ChatScrollView.swift
// Chappie
//
// WHY THIS FILE EXISTS:
// Scroll logic (auto-scroll on new messages, thinking indicator) was embedded
// directly in ContentView's body. This component owns all message list rendering.
//
// FLOATING PANELS LAYOUT:
// ChatScrollView fills the entire ZStack behind the floating panels.
// It does NOT know about InputMorphView height directly.
// Instead it receives headerHeight and footerHeight — transparent spacers at the
// top and bottom of the VStack inside ScrollView.
// This guarantees the first and last messages are always fully readable
// regardless of the panel heights (including dynamic growth of the input editor).
//
// AUTO-SCROLL POLICY:
// Scroll to bottom happens in exactly three cases:
//   1. footerHeight first becomes non-zero — this is the true "layout ready" moment.
//      After that, initial scroll is marked done and footerHeight changes are ignored.
//   2. onChange(messages) — new message added to the chat.
//   3. onChange(streamingText) — Chappie is streaming a response (live bubble grows).
// Intentionally NOT scrolling when footerHeight changes after initial scroll
// so the user can freely read mid-chat while typing a long message.

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

    /// Height of the top floating panel — used as a transparent header spacer
    /// so the first message is never hidden behind the panel.
    let headerHeight: CGFloat

    /// Height of the bottom floating panel — used as a transparent footer spacer
    /// so the last message is never hidden behind the input panel.
    let footerHeight: CGFloat

    /// Extra breathing room below the last message.
    private let bottomGap: CGFloat = 12

    /// True after the very first non-zero footerHeight triggers the initial scroll.
    /// Prevents subsequent footerHeight changes (input field growing) from scrolling.
    @State private var initialScrollDone = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {

                    // Transparent header spacer — matches top floating panel height.
                    // Invisible but reserves space so messages start below the panel.
                    Color.clear
                        .frame(height: headerHeight)
                        .id("TopSpacer")

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

                    // Transparent footer spacer — matches bottom floating panel height.
                    // Invisible but reserves space so the last message stays above the panel.
                    Color.clear
                        .frame(height: footerHeight + bottomGap)
                        .id("BottomSpacer")
                }
                .padding(.horizontal, 16)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: messages)
                .animation(.easeInOut(duration: 0.25), value: isThinking)
                .animation(.easeInOut(duration: 0.3), value: streamingText.isEmpty)
            }
            // INITIAL SCROLL: fires once when footerHeight first becomes non-zero.
            // This is the true "layout ready" moment — the bottom panel has reported
            // its real height and the footer spacer has settled to its final size.
            // After this, footerHeight changes (user typing) do NOT trigger scrolling.
            .onChange(of: footerHeight) { _, newHeight in
                guard !initialScrollDone, newHeight > 0 else { return }
                initialScrollDone = true
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo("BottomSpacer", anchor: .bottom)
                }
            }
            // Case 2: new message sent or received → scroll to bottom.
            .onChange(of: messages) { _, _ in
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo("BottomSpacer", anchor: .bottom)
                }
            }
            // Scroll when thinking starts so the spinner/bubble is visible.
            .onChange(of: isThinking) { _, isThinking in
                if isThinking {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo("BottomSpacer", anchor: .bottom)
                    }
                }
            }
            // Case 3: streaming response is growing → keep bottom pinned.
            .onChange(of: streamingText) { _, _ in
                proxy.scrollTo("BottomSpacer", anchor: .bottom)
            }
        }
    }

    // MARK: - Subviews

    /// Welcome message for empty chat.
    ///
    /// Design: neutral left-aligned bubble — like Chappie's first message.
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
    /// MarkdownTextView handles unclosed blocks gracefully.
    ///
    /// COST IN BOTTOM-RIGHT CORNER:
    /// ZStack alignment: .bottomTrailing pins the cost label over content.
    private var streamingBubble: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {

                HStack(alignment: .bottom, spacing: 0) {
                    MarkdownTextView(text: streamingText, fontSize: 14)
                        .contentTransition(.interpolate)
                        .animation(.linear(duration: 0.08), value: streamingText)

                    BlinkingCursor()
                        .padding(.bottom, 1)
                }
                .padding(.bottom, 18)

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
        headerHeight: 80,
        footerHeight: 80
    )
    .frame(width: 650, height: 500)
    .background(Color(NSColor.windowBackgroundColor))
}

#Preview("Empty chat") {
    ChatScrollView(
        messages: [],
        isThinking: false,
        streamingText: "",
        runningCost: 0.0,
        headerHeight: 60,
        footerHeight: 80
    )
    .frame(width: 650, height: 300)
    .background(Color(NSColor.windowBackgroundColor))
}
