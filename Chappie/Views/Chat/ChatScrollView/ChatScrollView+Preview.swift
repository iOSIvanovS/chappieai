// ChatScrollView+Preview.swift
// Chappie

import SwiftUI

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
