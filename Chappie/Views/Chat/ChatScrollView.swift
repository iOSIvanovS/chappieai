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
// VSTACK (PAGINATION OVER LAZYVSTACK):
// Messages are rendered in a plain VStack — all displayed messages are always in the
// render tree. This eliminates the disappearing-messages bug caused by LazyVStack's
// cell recycling when switching threads or scrolling.
// Performance is managed by pagination in ViewModel: only the last 50 messages are
// shown initially; older ones are loaded in batches of 30 via loadMoreMessages().
//
// SCROLL ANCHOR STRATEGY (prevents jumping during streaming):
// Each message has a stable .id(msg.id). Bottom sentinel is Color.clear.id("bottom").
// During streaming: scrollTo("bottom") is called on every streamingText change.
// This pins the view to the bottom WITHOUT layout recalculation jumping.
// Key insight: proxy.scrollTo without animation during streaming (instant snap),
// with animation only for discrete events (new message, thread switch).
//
// AUTO-SCROLL POLICY:
// Scroll to bottom happens in exactly four cases:
//   1. scrollToBottomTrigger changes — ViewModel incremented it after displayedMessages
//      was fully populated (end of resetPagination). Uses .task(id:) instead of onChange
//      because .task(id:) is guaranteed to run AFTER the view body has been applied to
//      the layout tree. onChange fires during the render pass — before layout is committed.
//      A 50ms sleep inside the task gives the VStack time to measure its content.
//      This eliminates "bad range for [%{public}s]" which was caused by proxy.scrollTo
//      firing before ScrollView knew about the "bottom" anchor geometry.
//   2. footerHeight first becomes non-zero — "layout ready" moment on first launch.
//      After that, footerHeight changes are ignored (user typing grows the input field).
//   3. onChange(messages.count) — new message added to the chat.
//   4. onChange(streamingText) — Chappie is streaming a response (live bubble grows).
// Intentionally NOT scrolling when footerHeight changes after initial scroll
// so the user can freely read mid-chat while typing a long message.
//
// SCROLL TRIGGER FIX (UX-SCROLL-TRIGGER, v2):
// Previously used onChange(of: scrollToBottomTrigger) + DispatchQueue.main.async.
// Problem: DispatchQueue.main.async defers by one runloop tick, but SwiftUI layout
// is also async and may take multiple ticks. scrollTo fired before ScrollView had
// committed the new VStack geometry, causing "bad range" warnings.
// Fix: replaced onChange with .task(id: scrollToBottomTrigger).
// .task(id:) is a SwiftUI-native lifecycle hook that runs AFTER the view body
// has been applied. Combined with a 50ms Task.sleep, this gives the layout engine
// enough time to measure the new VStack content before scrollTo is evaluated.
// This is the correct and idiomatic SwiftUI solution for post-layout side effects.
//
// LOAD MORE (PAGINATION):
// A "Load earlier messages" button appears at the top when hasMoreMessages == true.
// Tapping it calls onLoadMore() which prepends the previous batch.
// After loading, scroll position is preserved — no jump to top or bottom.
//
// SCROLLBAR:
// Hidden via scrollIndicators(.never) — not needed in this chat UI aesthetic.

import SwiftUI

/// Scrollable message list with auto-scroll, paginated VStack rendering, and streaming anchor.
///
/// IMPORTANT: Accepts `displayedMessages` — paginated slice from ViewModel.
/// Pagination logic lives in ViewModel, not here.
struct ChatScrollView: View {

    /// Scroll-to-bottom trigger from ViewModel.
    ///
    /// SCROLL TRIGGER FIX v2 (UX-SCROLL-TRIGGER):
    /// Incremented by ViewModel at the END of resetPagination(), after displayedMessages
    /// is fully populated. Watched via .task(id:) — not onChange — because .task(id:)
    /// runs after the view body has been committed to the layout tree.
    let scrollToBottomTrigger: Int

    /// Paginated message slice (last N messages, grows upward via onLoadMore).
    let messages: [ChatMessage]

    /// True when there are older messages not yet loaded into the displayed slice.
    let hasMoreMessages: Bool

    /// Called when user taps "Load earlier messages" — ViewModel prepends more.
    let onLoadMore: () -> Void

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

    /// True after the first scroll-to-bottom on app launch or thread switch.
    /// Prevents footerHeight changes (user typing) from scrolling mid-chat.
    @State private var initialScrollDone = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Plain VStack — all displayed messages are always in the render tree.
                // Performance is managed by pagination: only the last 50 messages are
                // shown initially. LazyVStack was causing disappearing-messages bugs.
                VStack(spacing: 16) {

                    // Transparent header spacer — matches top floating panel height.
                    Color.clear
                        .frame(height: headerHeight)
                        .id("top")

                    // "Load earlier messages" button — visible when older messages exist.
                    if hasMoreMessages {
                        loadMoreButton
                            .transition(.opacity)
                    }

                    // Welcome screen — shown only when chat is empty
                    if messages.isEmpty && !isThinking {
                        welcomeMessage
                            .transition(.opacity)
                    } else {
                        ForEach(messages) { msg in
                            MessageBubbleView(msg: msg)
                                // Stable ID per message — VStack uses this for identity.
                                .id(msg.id)
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

                    // Transparent footer spacer + bottom sentinel.
                    // scrollTo("bottom") always lands here — below the last message.
                    Color.clear
                        .frame(height: footerHeight + bottomGap)
                        .id("bottom")
                }
                .padding(.horizontal, 16)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: messages.count)
                .animation(.easeInOut(duration: 0.25), value: isThinking)
                .animation(.easeInOut(duration: 0.3), value: streamingText.isEmpty)
            }
            .scrollIndicators(.never)
            // THREAD SWITCH: .task(id:) runs AFTER the view body has been committed to layout.
            // This is the key difference from onChange — onChange fires DURING the render pass,
            // before the layout engine has processed the new VStack content.
            // .task(id:) is SwiftUI's post-layout hook: safe to call proxy.scrollTo here.
            // The 50ms sleep gives the VStack additional time to measure its full height
            // before scrollTo evaluates the "bottom" anchor geometry.
            // Without this sleep, scrollTo can still fire before ScrollView has measured
            // the new content on slow devices or large message lists.
            .task(id: scrollToBottomTrigger) {
                // Skip the very first trigger (value = 0 on init before any thread loads).
                guard scrollToBottomTrigger > 0 else { return }
                initialScrollDone = false
                // 50ms: enough for VStack layout to complete, imperceptible to the user.
                try? await Task.sleep(nanoseconds: 50_000_000)
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                initialScrollDone = true
            }
            // INITIAL SCROLL: fires once when footerHeight first becomes non-zero on launch.
            .onChange(of: footerHeight) { _, newHeight in
                guard !initialScrollDone, newHeight > 0 else { return }
                initialScrollDone = true
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            // New message added → animated scroll to bottom.
            // Keyed on count, not the array itself — avoids triggering on message content edits.
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            // Thinking starts → scroll so spinner/bubble is visible.
            .onChange(of: isThinking) { _, isThinking in
                if isThinking {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            // STREAMING: NO animation — instant snap prevents the "jumping" effect.
            // Animation here causes layout recalculation on every token, which makes
            // the scroll position bounce. Instant scrollTo keeps the view pinned smoothly.
            .onChange(of: streamingText) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - Subviews

    /// "Load earlier messages" button — shown at the top when hasMoreMessages == true.
    private var loadMoreButton: some View {
        Button(action: onLoadMore) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 13, weight: .medium))
                Text("Загрузить предыдущие сообщения")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    /// Welcome message for empty chat.
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
                    .foregroundStyle(.secondary)
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
        scrollToBottomTrigger: 1,
        messages: [
            .message(isUser: true, text: "Show me a code example"),
            .message(
                isUser: false,
                text: "Sure! Here's an example:\n\n```swift\n// Example ViewModel\n@Observable\nfinal class ViewModel {\n    var count = 0\n}\n```\n\nUse **@Observable** for automatic tracking.",
                cost: 0.42
            ),
        ],
        hasMoreMessages: true,
        onLoadMore: {},
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
        scrollToBottomTrigger: 0,
        messages: [],
        hasMoreMessages: false,
        onLoadMore: {},
        isThinking: false,
        streamingText: "",
        runningCost: 0.0,
        headerHeight: 60,
        footerHeight: 80
    )
    .frame(width: 650, height: 300)
    .background(Color(NSColor.windowBackgroundColor))
}
