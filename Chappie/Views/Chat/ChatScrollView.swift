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
//   2. footerHeight becomes non-zero AND messages are already loaded — "layout ready" moment.
//      Guard: only fires when messages.count > 0 to avoid scrollTo on empty layout.
//   3. onChange(messages.count) — new message added to the chat.
//   4. onChange(streamingText) — Chappie is streaming a response (live bubble grows).
// Intentionally NOT scrolling when footerHeight changes after initial scroll
// so the user can freely read mid-chat while typing a long message.
//
// BUBBLE WIDTH STRATEGY:
// No GeometryReader. No environment injection.
// Each bubble uses HStack + Spacer(minLength: 40) on the opposite side.
// SwiftUI distributes the available width: bubble gets ~75%, Spacer gets ~25%.
// The window can resize freely — no measured value creates a minimum-width floor.
//
// NOTE ON "bad range for [%{public}s]" IN XCODE CONSOLE:
// This warning is NOT caused by our code. It is an internal CoreData/SwiftData OSLog
// decode error that fires when SwiftData performs its first PostSaveMaintenance
// (incremental_vacuum) after the ModelContainer opens. It is a system-level log
// formatting issue in Apple's CoreData framework — harmless, does not affect the app.
// It appears immediately after "[ChappieViewModel] Loaded N providers" because that
// is when SwiftData completes its first write operation.
//
// LOAD MORE (PAGINATION):
// A "Load earlier messages" button appears at the top when hasMoreMessages == true.
// Tapping it calls onLoadMore() which prepends the previous batch.
// After loading, scroll position is preserved — no jump to top or bottom.
//
// SCROLLBAR:
// Hidden via scrollIndicators(.never) — not needed in this chat UI aesthetic.
//
// LOADING HISTORY INDICATOR (UX-LOADING):
// isLoadingHistory is forwarded from ViewModel.isLoadingThread.
// While true: a centered ProgressView is shown instead of messages or welcome screen.
// This prevents the "flash of welcome message" on app launch while SwiftData loads.

import SwiftUI

/// Scrollable message list with auto-scroll, paginated VStack rendering, and streaming anchor.
///
/// IMPORTANT: Accepts `displayedMessages` — paginated slice from ViewModel.
/// Pagination logic lives in ViewModel, not here.
struct ChatScrollView: View {

    let scrollToBottomTrigger: Int
    let messages: [ChatMessage]
    let hasMoreMessages: Bool
    let onLoadMore: () -> Void
    let isThinking: Bool
    let isLoadingHistory: Bool
    let streamingText: String
    let runningCost: Double
    let headerHeight: CGFloat
    let footerHeight: CGFloat

    private let bottomGap: CGFloat = 12

    @State private var initialScrollDone = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {

                    Color.clear
                        .frame(height: headerHeight)
                        .id("top")

                    if isLoadingHistory {
                        historyLoadingIndicator
                            .transition(.opacity)
                    } else {
                        if hasMoreMessages {
                            loadMoreButton
                                .transition(.opacity)
                        }

                        if messages.isEmpty && !isThinking {
                            welcomeMessage
                                .transition(.opacity)
                        } else {
                            ForEach(messages) { msg in
                                MessageBubbleView(msg: msg)
                                    .id(msg.id)
                            }
                        }

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
                    }

                    Color.clear
                        .frame(height: footerHeight + bottomGap)
                        .id("bottom")
                }
                .padding(.horizontal, 16)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: messages.count)
                .animation(.easeInOut(duration: 0.25), value: isThinking)
                .animation(.easeInOut(duration: 0.3), value: streamingText.isEmpty)
                .animation(.easeInOut(duration: 0.2), value: isLoadingHistory)
            }
            .scrollIndicators(.never)
            .task(id: scrollToBottomTrigger) {
                guard scrollToBottomTrigger > 0 else { return }
                initialScrollDone = false
                try? await Task.sleep(nanoseconds: 50_000_000)
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                initialScrollDone = true
            }
            .onChange(of: footerHeight) { _, newHeight in
                guard !initialScrollDone, newHeight > 0, messages.count > 0 else { return }
                initialScrollDone = true
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: isThinking) { _, isThinking in
                if isThinking {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .onChange(of: streamingText) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - Subviews

    private var historyLoadingIndicator: some View {
        ProgressView()
            .controlSize(.regular)
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
    }

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
        isLoadingHistory: false,
        streamingText: "Also you can add `@MainActor` for **thread safety**...",
        runningCost: 1.23,
        headerHeight: 80,
        footerHeight: 80
    )
    .frame(width: 650, height: 500)
    .background(Color(NSColor.windowBackgroundColor))
}

#Preview("Loading history") {
    ChatScrollView(
        scrollToBottomTrigger: 0,
        messages: [],
        hasMoreMessages: false,
        onLoadMore: {},
        isThinking: false,
        isLoadingHistory: true,
        streamingText: "",
        runningCost: 0.0,
        headerHeight: 60,
        footerHeight: 80
    )
    .frame(width: 650, height: 300)
    .background(Color(NSColor.windowBackgroundColor))
}

#Preview("Empty chat") {
    ChatScrollView(
        scrollToBottomTrigger: 0,
        messages: [],
        hasMoreMessages: false,
        onLoadMore: {},
        isThinking: false,
        isLoadingHistory: false,
        streamingText: "",
        runningCost: 0.0,
        headerHeight: 60,
        footerHeight: 80
    )
    .frame(width: 650, height: 300)
    .background(Color(NSColor.windowBackgroundColor))
}
