// TerminalLiveState.swift
// Chappie
//
// Isolated @Observable for the live terminal window (run_terminal/run_ssh streaming).
//
// WHY SEPARATE FROM StreamingState:
// Terminal output arrives in a completely different lifecycle than chat streaming —
// it starts/stops per tool call, not per message. Keeping it isolated means the
// terminal window subscribes only to this object, and nothing else in the app
// re-renders when shell output ticks in.

import SwiftUI

@Observable
@MainActor
final class TerminalLiveState {

    // True while a run_terminal/run_ssh call is executing — drives window visibility.
    var isActive: Bool = false

    // The command being executed, shown as the window title/header.
    var command: String = ""

    // Accumulated live output — appended to as chunks arrive.
    var outputText: String = ""

    /// Called when a terminal/ssh tool call starts.
    func start(command: String) {
        self.command = command
        self.outputText = ""
        self.isActive = true
    }

    /// Called for every output chunk as it arrives.
    func append(_ chunk: String) {
        outputText += chunk
    }

    /// Called when the tool call finishes — window auto-closes after a short delay
    /// so the user has time to see the final output.
    func finish() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }
            self.isActive = false
        }
    }

    func reset() {
        isActive = false
        command = ""
        outputText = ""
    }
}
