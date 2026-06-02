// StreamingState.swift
// Chappie
//
// CPU-13: Isolated @Observable for streaming-only state.
//
// WHY THIS EXISTS:
// ChappieViewModel is a single @Observable. SwiftUI tracks every property read
// during a view's body evaluation. ContentView reads viewModel.streamingText,
// viewModel.runningCost, viewModel.currentToolCall, viewModel.isThinking —
// so on every streaming token (30+ times/sec) SwiftUI invalidates the ENTIRE
// ContentView tree, including topPanel, bottomPanel, and all their children.
//
// By moving these four hot properties into a separate @Observable object,
// ContentView can pass it down as a plain `let` reference without reading it.
// Only ChatScrollView and InputMorphView read from it — they re-render in
// isolation, leaving topPanel and the rest of ContentView untouched.
//
// CPU-15: currentBalance MOVED HERE from ChappieViewModel.
// balance is updated via onBalanceUpdate during streaming — every token with cost info.
// Before this move: topPanel read viewModel.currentBalance → ContentView subscribed to
// ViewModel for balance → every balance update re-rendered topPanel + all its children.
// After: ModelPickerRow receives `streaming` reference and reads streaming.currentBalance
// directly — balance updates are isolated to ModelPickerRow only.
// ChappieViewModel keeps a backward-compat computed var that forwards to streaming.currentBalance.

import SwiftUI

@Observable
@MainActor
final class StreamingState {

    // Updated on every incoming token — 30+ times/sec during streaming.
    var streamingText: String = ""

    // Updated on every cost delta from the server.
    var runningCost: Double = 0.0

    // Set when a tool call is in progress; nil otherwise.
    var currentToolCall: String? = nil

    // True while the AI is generating a response.
    var isThinking: Bool = false

    // CPU-15: balance moved here — updates during streaming without invalidating ViewModel observers.
    // nil until first response received from server.
    var currentBalance: Double? = nil

    func reset() {
        streamingText = ""
        runningCost = 0.0
        currentToolCall = nil
        isThinking = false
        // currentBalance is NOT reset — it persists across requests.
    }
}
