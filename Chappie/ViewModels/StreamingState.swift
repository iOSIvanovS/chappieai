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
//
// CPU-23: currentToolCall THROTTLED to 200ms.
// thinkingView animates on every currentToolCall change (.animation value:).
// Tool calls arrive with every token during tool execution — 30+/sec.
// Throttle: _rawToolCall stores the real value, currentToolCall is the throttled
// public property. A Task fires at most once per 200ms to flush _rawToolCall → currentToolCall.
// Result: thinkingView re-renders at most 5x/sec instead of 30+/sec.

import SwiftUI

@Observable
@MainActor
final class StreamingState {

    // Updated on every incoming token — 30+ times/sec during streaming.
    var streamingText: String = ""

    // Updated on every cost delta from the server.
    var runningCost: Double = 0.0

    // CPU-23: throttled tool call label — updates at most every 200ms.
    // Views animate on this; _rawToolCall absorbs the high-frequency writes.
    var currentToolCall: String? = nil

    // True while the AI is generating a response.
    var isThinking: Bool = false

    // Localized "provider error, retry 2 of 5 in 4s" label while a failed request waits to be
    // re-sent. Takes priority over the tool-call label in the action bar; nil = no retry going on.
    var retryLabel: String? = nil

    // CPU-15: balance moved here — updates during streaming without invalidating ViewModel observers.
    // nil until first response received from server.
    var currentBalance: Double? = nil

    // MARK: - CPU-23: Throttle internals

    // Raw value written at full token rate — NOT observed by views.
    private var _rawToolCall: String? = nil
    private var _throttleTask: Task<Void, Never>? = nil

    /// Write tool call at full token rate — throttled flush to `currentToolCall` every 200ms.
    func setToolCall(_ value: String?) {
        _rawToolCall = value
        guard _throttleTask == nil else { return }
        _throttleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self else { return }
            self.currentToolCall = self._rawToolCall
            self._throttleTask = nil
        }
    }

    func reset() {
        streamingText = ""
        runningCost = 0.0
        currentToolCall = nil
        _rawToolCall = nil
        _throttleTask?.cancel()
        _throttleTask = nil
        isThinking = false
        retryLabel = nil
        // currentBalance is NOT reset — it persists across requests.
    }
}
