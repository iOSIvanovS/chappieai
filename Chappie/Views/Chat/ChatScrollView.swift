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
// regardless of the panel heights.
//
// CPU-16: STATIC FOOTER HEIGHT:
// footerHeight is now InputLayout.maxPanelHeight — a compile-time constant passed from ContentView.
// Previously footerHeight was a @State in ContentView updated via onHeightChange callback
// from InputMorphView on every keystroke. That caused:
//   editorHeight → onHeightChange → bottomPanelHeight state → ContentView layout pass
//   → ChatScrollView re-render → footerHeight spacer update → scroll position recalc.
// Now footerHeight never changes at runtime → no layout pass from typing.
// onChange(of: footerHeight) removed — it was the "layout ready" guard that triggered
// initial scroll-to-bottom when the panel first appeared. Since footerHeight is now a
// constant (non-zero from the first render), we use scrollToBottomTrigger exclusively.
//
// VSTACK (PAGINATION OVER LAZYVSTACK):
// Messages are rendered in a plain VStack — all displayed messages are always in the
// render tree. This eliminates the disappearing-messages bug caused by LazyVStack's
// cell recycling when switching threads or scrolling.
// Performance is managed by pagination in ViewModel: only the last 30 messages are
// shown initially; older ones are loaded in batches of 30 via loadMoreMessages().
// The window is capped at 60 messages — trimming happens on both ends as user scrolls.
//
// SCROLL ANCHOR STRATEGY (prevents jumping during streaming):
// Each message has a stable .id(msg.id). Bottom sentinel is Color.clear.id("bottom").
// During streaming: scrollTo("bottom") is throttled to once per frame (16ms) via
// a Task-based debounce flag. This prevents layout thrashing on every token.
// Key insight: proxy.scrollTo without animation during streaming (instant snap),
// with animation only for discrete events (new message, thread switch).
//
// AUTO-SCROLL POLICY:
// Scroll to bottom happens in exactly three cases:
//   1. scrollToBottomTrigger changes — ViewModel incremented it after displayedMessages
//      was fully populated (end of resetPagination). Uses .task(id:) instead of onChange
//      because .task(id:) is guaranteed to run AFTER the view body has been applied to
//      the layout tree. onChange fires during the render pass — before layout is committed.
//      A 50ms sleep inside the task gives the VStack time to measure its content.
//   2. onChange(messages.count) — new message added to the chat.
//   3. onChange(streaming.streamingText) — Chappie is streaming (throttled to 1/frame).
//
// CPU-13: STREAMING ISOLATION:
// ChatScrollView receives `streaming: StreamingState` as a `let` reference.
// It reads streaming.isThinking, streaming.streamingText, streaming.runningCost directly.
// Because StreamingState is a separate @Observable, only ChatScrollView re-renders on
// token updates — ContentView and topPanel are NOT invalidated.
//
// NOTE ON "bad range for [%{public}s]" IN XCODE CONSOLE:
// This warning is NOT caused by our code. It is an internal CoreData/SwiftData OSLog
// decode error that fires when SwiftData performs its first PostSaveMaintenance
// (incremental_vacuum) after the ModelContainer opens. It is a system-level log
// formatting issue in Apple's CoreData framework — harmless, does not affect the app.
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
//
// MESSAGE RENDERING:
// ForEach uses MessageBubbleView directly — no GeometryReader, no background probe.
// Bubble width is capped at a fixed 500 pt constant via frame(maxWidth:).
// Window can resize freely without any layout side effects.

import SwiftUI

/// Scrollable message list with auto-scroll, paginated VStack rendering, and streaming anchor.
///
/// IMPORTANT: Accepts `displayedMessages` — paginated slice from ViewModel.
/// Pagination logic lives in ViewModel, not here.
struct ChatScrollView: View {

    /// Scroll-to-bottom trigger from ViewModel.
    let scrollToBottomTrigger: Int

    /// Paginated message slice (last N messages, grows upward via onLoadMore).
    let messages: [ChatMessage]

    /// True when there are older messages not yet loaded into the displayed slice.
    let hasMoreMessages: Bool

    /// Called when user taps "Load earlier messages" — ViewModel prepends more.
    let onLoadMore: () -> Void

    /// CPU-13: isolated streaming state — only this view subscribes to it.
    /// ContentView passes the reference without reading any of its properties.
    let streaming: StreamingState

    /// True while history is being loaded from SwiftData.
    let isLoadingHistory: Bool

    /// Height of the top floating panel — transparent header spacer.
    let headerHeight: CGFloat

    /// Height of the bottom floating panel — transparent footer spacer.
    /// CPU-16: always InputLayout.maxPanelHeight — never changes at runtime.
    let footerHeight: CGFloat

    private let bottomGap: CGFloat = 12

    // CPU-05: debounce flag — true while a scroll task is already scheduled.
    // Prevents firing proxy.scrollTo on every streaming token (dozens/sec).
    @State private var scrollPending = false

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

                        if messages.isEmpty && !streaming.isThinking {
                            welcomeMessage
                                .transition(.opacity)
                        } else {
                            ForEach(messages) { msg in
                                MessageBubbleView(msg: msg)
                                    .id(msg.id)
                            }
                        }

                        if streaming.isThinking {
                            if streaming.streamingText.isEmpty {
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
                .animation(.easeInOut(duration: 0.25), value: streaming.isThinking)
                .animation(.easeInOut(duration: 0.3), value: streaming.streamingText.isEmpty)
                .animation(.easeInOut(duration: 0.2), value: isLoadingHistory)
            }
            .scrollIndicators(.never)
            .task(id: scrollToBottomTrigger) {
                guard scrollToBottomTrigger > 0 else { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: streaming.isThinking) { _, isThinking in
                if isThinking {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .onChange(of: streaming.streamingText) { _, _ in
                // CPU-05: throttle scroll to once per frame (~16ms).
                guard !scrollPending else { return }
                scrollPending = true
                Task {
                    try? await Task.sleep(nanoseconds: 16_000_000)
                    proxy.scrollTo("bottom", anchor: .bottom)
                    scrollPending = false
                }
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

    /// Live streaming bubble with blinking cursor and running cost.
    private var streamingBubble: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                HStack(alignment: .bottom, spacing: 0) {
                    MarkdownTextView(text: streaming.streamingText, fontSize: 14)
                        .contentTransition(.interpolate)
                        .animation(.linear(duration: 0.08), value: streaming.streamingText)

                    BlinkingCursor()
                        .padding(.bottom, 1)
                }
                .padding(.bottom, 18)

                Text(String(format: "🪙 %.2f ₽", streaming.runningCost))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: streaming.runningCost))
                    .animation(.easeInOut(duration: 0.3), value: streaming.runningCost)
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
/// Extracted so its animation doesn't trigger full bubble redraws.
private struct BlinkingCursor: View {
    @State private var isVisible = true

    var body: some View {
        Text("▍")
            .font(.system(size: 14))
            .foregroundStyle(Color.accentColor)
            .opacity(isVisible ? 1 : 0)
            // CPU-07: drawingGroup() rasterizes the cursor into a Metal texture.
            // Its RepeatForever animation no longer invalidates the parent bubble view.
            .drawingGroup()
            .animation(
                .easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                value: isVisible
            )
            .onAppear { isVisible = false }
    }
}

// MARK: - Preview

#Preview("With history and streaming") {
    let streaming = StreamingState()
    streaming.isThinking = true
    streaming.streamingText = "Also you can add `@MainActor` for **thread safety**..."
    streaming.runningCost = 1.23

    return ChatScrollView(
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
        streaming: streaming,
        isLoadingHistory: false,
        headerHeight: 80,
        footerHeight: InputLayout.maxPanelHeight
    )
    .frame(width: 650, height: 500)
    .background(Color(NSColor.windowBackgroundColor))
}

#Preview("Empty chat") {
    let streaming = StreamingState()

    return ChatScrollView(
        scrollToBottomTrigger: 0,
        messages: [],
        hasMoreMessages: false,
        onLoadMore: {},
        streaming: streaming,
        isLoadingHistory: false,
        headerHeight: 60,
        footerHeight: InputLayout.maxPanelHeight
    )
    .frame(width: 650, height: 300)
    .background(Color(NSColor.windowBackgroundColor))
}
