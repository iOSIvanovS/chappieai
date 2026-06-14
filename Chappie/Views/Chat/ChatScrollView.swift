// ChatScrollView.swift
// Chappie
//
// Scrollable message list with auto-scroll, paginated VStack rendering, and streaming anchor.
//
// LOADING MESSAGES SPINNER (UX-LOADING):
// isLoadingHistory is true from the moment selectThread() starts until _syncTask
// fully completes (messages loaded + session assembled).
// While true: a centered DotsIndicator + "chat.loading" label is shown.
// This prevents the "flash of empty chat" during thread switch.
//
// See full design notes in the original file header (git history).

import SwiftUI

struct ChatScrollView: View {

    let scrollToBottomTrigger: Int
    let messages: [ChatMessage]
    let hasMoreMessages: Bool
    let onLoadMore: () -> Void

    // CPU-13: isolated streaming state — only this view subscribes to it.
    let streaming: StreamingState

    let isLoadingHistory: Bool
    let headerHeight: CGFloat

    // CPU-22: measured via onGeometryChange in ContentView, grows dynamically.
    let footerHeight: CGFloat

    // BUG-01 v6: anchor message ID set just before Load More prepend.
    let loadMoreAnchorId: UUID?
    let onLoadMoreScrollDone: () -> Void

    // CPU-05: debounce flag — true while a scroll task is already scheduled.
    @State private var scrollPending = false

    // BUBBLE WIDTH (RESIZE FIX v2): measured from the outer view (parent/window).
    @State private var availableWidth: CGFloat = 600

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {

                    Color.clear
                        .frame(height: headerHeight)
                        .id("top")

                    if isLoadingHistory {
                        threadLoadingIndicator
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.2), value: isLoadingHistory)
                    } else {
                        if hasMoreMessages {
                            loadMoreButton
                                .transition(.opacity)
                        }

                        ForEach(messages) { msg in
                            MessageBubbleView(msg: msg, availableWidth: availableWidth)
                                .id(msg.id)
                        }

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

                    Color.clear
                        .frame(height: 0)
                        .id("bottom")

                    Color.clear
                        .frame(height: footerHeight)
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.never)
            .task(id: scrollToBottomTrigger) {
                guard scrollToBottomTrigger > 0 else { return }
                try? await Task.sleep(nanoseconds: 150_000_000)
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo("bottom", anchor: .top)
                }
            }
            .onChange(of: loadMoreAnchorId) { _, newAnchorId in
                guard let anchorId = newAnchorId else { return }
                Task {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(anchorId, anchor: .center)
                    }
                    onLoadMoreScrollDone()
                }
            }
            .onChange(of: messages.count) { _, _ in
                guard loadMoreAnchorId == nil else { return }
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
                guard !scrollPending else { return }
                scrollPending = true
                Task {
                    try? await Task.sleep(nanoseconds: 16_000_000)
                    proxy.scrollTo("bottom", anchor: .top)
                    scrollPending = false
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { geo in
            geo.size.width
        } action: { newWidth in
            if newWidth > 0 { availableWidth = newWidth }
        }
    }

    // MARK: - Subviews

    /// Spinner shown while thread messages are being loaded from SwiftData.
    /// Replaces the flash of empty chat that was visible before _syncTask completed.
    private var threadLoadingIndicator: some View {
        VStack(spacing: 12) {
            DotsIndicator()
            Text("chat.loading")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var loadMoreButton: some View {
        Button(action: onLoadMore) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 13, weight: .medium))
                Text("chat.load_earlier")
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

    // CPU-24: plain text during stream — no Markdown parsing overhead.
    private var streamingBubble: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                HStack(alignment: .bottom, spacing: 0) {
                    StreamingTextView(text: streaming.streamingText)
                    BlinkingCursor()
                        .padding(.bottom, 1)
                }
                .padding(.bottom, 18)

                // CPU-27: animation removed — fires on every token (30+/sec).
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
            .frame(maxWidth: max(availableWidth * 0.88, 220))

            Spacer(minLength: 40)
        }
    }
}

// MARK: - DotsIndicator

// CPU-29: TimelineView-driven waiting indicator — zero @State, zero SwiftUI invalidation.
private struct DotsIndicator: View {
    private let dotSize: CGFloat = 7
    private let spacing: CGFloat = 5
    private let period: Double = 1.08

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: spacing) {
                dot(t: t, delay: 0.00)
                dot(t: t, delay: 0.18)
                dot(t: t, delay: 0.36)
            }
            .drawingGroup()
        }
    }

    private func dot(t: Double, delay: Double) -> some View {
        let phase = (t - delay).truncatingRemainder(dividingBy: period) / period
        let v = (sin(phase * 2 * .pi - .pi / 2) + 1) / 2
        return Circle()
            .fill(Color.secondary.opacity(0.6))
            .frame(width: dotSize, height: dotSize)
            .scaleEffect(0.5 + v * 0.5)
            .opacity(0.3 + v * 0.7)
    }
}

// MARK: - StreamingTextView

// CPU-24: Plain text renderer for the live streaming bubble — no Markdown parsing.
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

// CPU-30: TimelineView-driven blinking cursor — zero @State, zero SwiftUI invalidation.
private struct BlinkingCursor: View {
    private static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    var body: some View {
        TimelineView(.periodic(from: Self.epoch, by: 0.5)) { timeline in
            let slot = Int(timeline.date.timeIntervalSinceReferenceDate / 0.5)
            Text(verbatim: "▍")
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
        footerHeight: InputLayout.minPanelHeight,
        loadMoreAnchorId: nil,
        onLoadMoreScrollDone: {}
    )
    .frame(width: 650, height: 500)
    .background(Color(NSColor.windowBackgroundColor))
}

#Preview("Loading spinner") {
    let streaming = StreamingState()

    return ChatScrollView(
        scrollToBottomTrigger: 0,
        messages: [],
        hasMoreMessages: false,
        onLoadMore: {},
        streaming: streaming,
        isLoadingHistory: true,
        headerHeight: 80,
        footerHeight: InputLayout.minPanelHeight,
        loadMoreAnchorId: nil,
        onLoadMoreScrollDone: {}
    )
    .frame(width: 650, height: 300)
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
        footerHeight: InputLayout.minPanelHeight,
        loadMoreAnchorId: nil,
        onLoadMoreScrollDone: {}
    )
    .frame(width: 650, height: 300)
    .background(Color(NSColor.windowBackgroundColor))
}
