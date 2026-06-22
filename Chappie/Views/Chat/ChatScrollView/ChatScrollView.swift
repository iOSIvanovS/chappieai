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
    @State var scrollPending = false

    // BUBBLE WIDTH (RESIZE FIX v2): measured from the outer view (parent/window).
    @State var availableWidth: CGFloat = 600

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
}
