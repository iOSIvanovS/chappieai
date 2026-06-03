// ChatScrollView.swift
// Chappie
//
// WHY THIS FILE EXISTS:
// Scroll logic (auto-scroll on new messages, thinking indicator) was embedded
// directly in ContentView's body. This component owns all message list rendering.
//
// FLOATING PANELS LAYOUT:
// ChatScrollView fills the entire ZStack behind the floating panels.
// The input panel is floating (ZStack overlay) — ScrollView viewport extends
// to the full window height. The footer spacer below the sentinel provides
// clearance so the last message is never hidden behind the input panel.
//
// SCROLL ANCHOR STRATEGY:
// Sentinel "bottom" has zero height and sits BEFORE the footer spacer.
// anchor: .top → the TOP of the sentinel aligns with the BOTTOM of the viewport.
// This means the last message lands just above the sentinel — just above the
// input panel. The footer spacer (footerHeight) below the sentinel provides
// physical clearance from the actual panel chrome.
// WHY NOT anchor: .bottom — that would align the BOTTOM of the sentinel with
// the viewport bottom, placing it below the panel — last message gets covered.
//
// FOOTER HEIGHT (CPU-22):
// footerHeight = currentPanelHeight, measured via onGeometryChange in ContentView.
// This is the exact rendered height of InputMorphView — no manual formula, no gap.
// When the panel grows (multi-line text, attachment row), footerHeight grows too,
// so the user can always scroll the last message above the expanded panel.
// Previously: minPanelHeight (88pt) was static — expanding panel covered messages
// and the user couldn't scroll them into view.
//
// VSTACK (PAGINATION OVER LAZYVSTACK):
// Messages are rendered in a plain VStack — all displayed messages are always in the
// render tree. This eliminates the disappearing-messages bug caused by LazyVStack's
// cell recycling when switching threads or scrolling.
// Performance is managed by pagination in ViewModel: only the last 30 messages are
// shown initially; older ones are loaded in batches of 30 via loadMoreMessages().
// The window is capped at 60 messages — trimming happens on both ends as user scrolls.
//
// AUTO-SCROLL POLICY:
// Scroll to bottom happens in exactly three cases:
//   1. scrollToBottomTrigger changes — ViewModel incremented it after displayedMessages
//      was fully populated (end of resetPagination). Uses .task(id:) instead of onChange
//      because .task(id:) is guaranteed to run AFTER the view body has been applied to
//      the layout tree. onChange fires during the render pass — before layout is committed.
//      A 150ms sleep gives the VStack time to measure its content on cold start.
//   2. onChange(messages.count) — new message added to the chat.
//   3. onChange(streaming.streamingText) — Chappie is streaming (throttled to 1/frame).
//
// CPU-13: STREAMING ISOLATION:
// ChatScrollView receives `streaming: StreamingState` as a `let` reference.
// It reads streaming.isThinking, streaming.streamingText, streaming.runningCost directly.
// Because StreamingState is a separate @Observable, only ChatScrollView re-renders on
// token updates — ContentView and topPanel are NOT invalidated.
//
// CPU-24: STREAMING BUBBLE — PLAIN TEXT DURING STREAM:
// MarkdownTextView.init() calls MarkdownParser.parse() on every render.
// During streaming that means full re-parse on every token (30+/sec), growing text.
// Fix: streamingBubble uses StreamingTextView (plain Text) — zero parse cost.
// MarkdownTextView is only used in MessageBubbleView for completed messages.
//
// CPU-25: ANIMATION SCOPE NARROWED:
// .animation(.easeInOut, value: streaming.isThinking) was on the outer VStack —
// it animated the entire message list on every thinking state change.
// Now each animated element carries its own targeted animation.
//
// CPU-27: runningCost ANIMATION REMOVED:
// .animation(.easeInOut(0.3), value: runningCost) fired on every token with cost info.
// contentTransition(.numericText(value:)) is kept for visual smoothness but the
// animation driver is removed — SwiftUI uses the default transaction instead.
//
// CPU-28: ProgressView() REPLACED WITH DotsIndicator:
// ProgressView() on macOS is NSProgressIndicator — a CoreAnimation-driven spinning
// control that renders at 60fps regardless of visibility context.
// Two instances were present: thinkingIndicator (in chat) and historyLoadingIndicator.
// historyLoadingIndicator replaced with DotsIndicator — animated via TimelineView(.animation).
//
// CPU-29: DotsIndicator MIGRATED FROM @State TO TimelineView:
// Previous DotsIndicator used three @State-driven .repeatForever animations.
// Each @State change triggers SwiftUI invalidation — even with drawingGroup().
// SwiftUI still schedules layout passes for every animation tick on its side.
// Fix: TimelineView(.animation) — single display-link shared across the whole screen.
// Phase is computed mathematically from Date — zero @State, zero SwiftUI invalidation.
// The view body is pure: same input → same output. No side effects, no timers.
//
// CPU-30: BlinkingCursor MIGRATED FROM @State TO TimelineView:
// Previous BlinkingCursor used @State isVisible + .repeatForever animation.
// drawingGroup() offloads GPU render but SwiftUI still runs its invalidation pipeline
// on every @State toggle (~2/sec) — AttributeGraph diff + layout pass on macOS.
// Fix: TimelineView(.periodic(from:by:)) — cursor phase computed from Date.
// Zero @State, zero SwiftUI invalidation. Same visual result, ~50% less CPU.
//
// CPU-31: thinkingIndicator (DotsIndicator bubble) REMOVED:
// While isThinking=true and streamingText.isEmpty, the DotsIndicator bubble was rendered.
// DotsIndicator uses TimelineView(.animation) — a 60fps display-link that runs
// continuously regardless of visibility, causing ~50% CPU during AI "thinking" pauses
// (no network, no disk, just waiting for the backend to respond).
// The bubble was visually redundant: the bottom InputMorphView panel already shows
// the gear icon + current action label during thinking. The dots bubble was hidden
// behind the panel or invisible in most layouts.
// Fix: removed thinkingIndicator entirely. Only streamingBubble is shown when
// isThinking=true — and only once text actually starts arriving.
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
// While true: a centered DotsIndicator is shown instead of messages.
// This prevents the "flash of empty chat" on app launch while SwiftData loads.
//
// EMPTY STATE:
// When messages are empty and not loading — show nothing.
// The AI sends a live greeting as the first message when a new thread is created,
// so there is no need for a static placeholder. Old threads load their real history.
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

    /// Height of the bottom floating panel — exact measured height of InputMorphView.
    /// CPU-22: measured via onGeometryChange in ContentView, grows with the panel.
    let footerHeight: CGFloat

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

                    // CPU-25: isLoadingHistory animation is scoped to its own element only.
                    if isLoadingHistory {
                        historyLoadingIndicator
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.2), value: isLoadingHistory)
                    } else {
                        if hasMoreMessages {
                            loadMoreButton
                                .transition(.opacity)
                        }

                        ForEach(messages) { msg in
                            MessageBubbleView(msg: msg)
                                .id(msg.id)
                        }

                        // CPU-31: thinkingIndicator (DotsIndicator bubble) removed.
                        // Only show streamingBubble once text actually arrives.
                        // The bottom panel already indicates thinking state visually.
                        if streaming.isThinking && !streaming.streamingText.isEmpty {
                            streamingBubble
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity
                                ))
                                .animation(.easeInOut(duration: 0.3), value: streaming.streamingText.isEmpty)
                                .id("thinking-streaming")
                        }
                    }

                    // Sentinel: zero height, anchor: .top.
                    // TOP of this marker aligns with the BOTTOM of the viewport on scroll.
                    // Result: last message sits just above the input panel.
                    Color.clear
                        .frame(height: 0)
                        .id("bottom")

                    // Footer spacer: exact panel height — provides physical clearance
                    // so content isn't hidden behind the floating input panel.
                    // CPU-22: footerHeight = measured InputMorphView height, grows dynamically.
                    Color.clear
                        .frame(height: footerHeight)
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.never)
            .task(id: scrollToBottomTrigger) {
                guard scrollToBottomTrigger > 0 else { return }
                // 150ms — enough for VStack to measure content on cold start.
                try? await Task.sleep(nanoseconds: 150_000_000)
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo("bottom", anchor: .top)
                }
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo("bottom", anchor: .top)
                }
            }
            .onChange(of: streaming.isThinking) { _, isThinking in
                if isThinking {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo("bottom", anchor: .top)
                    }
                }
            }
            .onChange(of: streaming.streamingText) { _, _ in
                // CPU-05: throttle scroll to once per frame (~16ms).
                guard !scrollPending else { return }
                scrollPending = true
                Task {
                    try? await Task.sleep(nanoseconds: 16_000_000)
                    proxy.scrollTo("bottom", anchor: .top)
                    scrollPending = false
                }
            }
        }
    }

    // MARK: - Subviews

    /// CPU-29: DotsIndicator — TimelineView-driven, zero @State.
    private var historyLoadingIndicator: some View {
        DotsIndicator()
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

    /// Live streaming bubble — plain text during stream, no Markdown parsing.
    /// CPU-24: MarkdownTextView.init() calls MarkdownParser.parse() on every render.
    /// During streaming that means full re-parse on every token (30+/sec), growing text.
    /// StreamingTextView renders plain Text — zero parse overhead during stream.
    /// Markdown is applied only after stream completes (MessageBubbleView).
    private var streamingBubble: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                HStack(alignment: .bottom, spacing: 0) {
                    StreamingTextView(text: streaming.streamingText)
                    BlinkingCursor()
                        .padding(.bottom, 1)
                }
                .padding(.bottom, 18)

                // CPU-27: .animation(.easeInOut(0.3), value: runningCost) removed —
                // it fired on every token with cost info (30+/sec).
                // contentTransition is kept for visual smoothness on the numeric flip.
                Text(String(format: "🪙 %.2f ₽", streaming.runningCost))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: streaming.runningCost))
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

// MARK: - DotsIndicator

/// CPU-29: TimelineView-driven waiting indicator — zero @State, zero SwiftUI invalidation.
///
/// WHY TimelineView over @State + repeatForever:
/// The old implementation used three @State booleans with .repeatForever animations.
/// Even with drawingGroup(), SwiftUI still schedules layout passes on its side for each
/// animation tick — because @State changes trigger the SwiftUI invalidation pipeline.
/// This caused ~50% CPU while waiting for the AI backend (no network, no disk, just dots).
///
/// TimelineView(.animation) uses a single shared display-link for the entire screen.
/// Phase is computed mathematically from the current Date — no @State, no invalidation.
/// The view body is a pure function: same timestamp → same pixels. Zero side effects.
///
/// NOTE: DotsIndicator is only used for historyLoadingIndicator (loading old messages).
/// The thinkingIndicator bubble was removed (CPU-31) — the bottom panel shows thinking state.
private struct DotsIndicator: View {
    private let dotSize: CGFloat = 7
    private let spacing: CGFloat = 5
    private let period: Double = 1.08  // full pulse cycle in seconds

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: spacing) {
                dot(t: t, delay: 0.00)
                dot(t: t, delay: 0.18)
                dot(t: t, delay: 0.36)
            }
            // Single Metal texture for all three dots — one GPU draw call.
            .drawingGroup()
        }
    }

    /// Computes scale and opacity from a sine wave offset by `delay` seconds.
    /// sin oscillates -1…1 → normalized to 0…1 for smooth pulse.
    private func dot(t: Double, delay: Double) -> some View {
        let phase = (t - delay).truncatingRemainder(dividingBy: period) / period
        let v = (sin(phase * 2 * .pi - .pi / 2) + 1) / 2  // 0…1, starts at 0
        return Circle()
            .fill(Color.secondary.opacity(0.6))
            .frame(width: dotSize, height: dotSize)
            .scaleEffect(0.5 + v * 0.5)
            .opacity(0.3 + v * 0.7)
    }
}

// MARK: - StreamingTextView

/// CPU-24: Plain text renderer for the live streaming bubble.
/// No Markdown parsing — just renders the raw text as-is with basic font styling.
/// WHY: MarkdownTextView calls MarkdownParser.parse() in init() — O(n) on every token.
/// During a 500-token stream that's 500 full parses of growing text.
/// Plain Text() is O(1) — just a string assignment.
private struct StreamingTextView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .lineSpacing(4)
            .foregroundStyle(Color.primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - BlinkingCursor

/// CPU-30: TimelineView-driven blinking cursor — zero @State, zero SwiftUI invalidation.
///
/// WHY TimelineView over @State + repeatForever:
/// The old implementation toggled @State isVisible every 500ms with .repeatForever.
/// drawingGroup() offloads GPU render but SwiftUI still runs its full invalidation
/// pipeline on every @State toggle: AttributeGraph diff + layout pass on macOS.
/// During "thinking with text" state this caused ~50% CPU with no network activity.
///
/// TimelineView(.periodic(from:by:)) fires exactly 2× per second.
/// Cursor visibility is computed from Date parity — no @State, no invalidation.
/// The view body is a pure function: same timestamp → same pixel. Zero side effects.
private struct BlinkingCursor: View {
    // Anchor to a fixed reference point so all cursors blink in sync.
    private static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    var body: some View {
        TimelineView(.periodic(from: Self.epoch, by: 0.5)) { timeline in
            // Count 0.5s slots elapsed since epoch; even = visible, odd = hidden.
            let slot = Int(timeline.date.timeIntervalSinceReferenceDate / 0.5)
            Text("▍")
                .font(.system(size: 14))
                .foregroundStyle(Color.accentColor)
                .opacity(slot.isMultiple(of: 2) ? 1 : 0)
                .drawingGroup()
        }
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
        footerHeight: InputLayout.minPanelHeight
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
        footerHeight: InputLayout.minPanelHeight
    )
    .frame(width: 650, height: 300)
    .background(Color(NSColor.windowBackgroundColor))
}

#Preview("Thinking — waiting for first token") {
    let streaming = StreamingState()
    streaming.isThinking = true
    // streamingText is empty — no bubble shown, bottom panel handles the indicator.

    return ChatScrollView(
        scrollToBottomTrigger: 0,
        messages: [
            .message(isUser: true, text: "Думай...")
        ],
        hasMoreMessages: false,
        onLoadMore: {},
        streaming: streaming,
        isLoadingHistory: false,
        headerHeight: 60,
        footerHeight: InputLayout.minPanelHeight
    )
    .frame(width: 650, height: 300)
    .background(Color(NSColor.windowBackgroundColor))
}
