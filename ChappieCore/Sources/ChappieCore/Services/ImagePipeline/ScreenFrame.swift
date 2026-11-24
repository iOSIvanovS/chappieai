// ScreenFrame.swift
// ChappieCore
//
// The live picture of the screen for the current computer-use turn.
//
// WHY IT IS NOT HISTORY: the picture changes on every computer_* call. Sitting in the message
// history it is a mutable block inside the cached prefix, and every call rewrites the entire
// prefix after it (measured on RouterAI: 15% cache read, ~50k tokens written per step).
// Appended as the LAST message of a request instead, it stays past the cache breakpoint and
// costs only itself.
//
// HISTORY STAYS APPEND-ONLY. A tool result is written once and never edited: editing any past
// message re-opens the prefix and costs a full rewrite, which is far more expensive than
// carrying a short line of text for every call.

import Foundation

public enum ScreenFrame {

    /// Role of the synthetic message that carries the live frame.
    ///
    /// It never enters the saved history: the orchestrator appends it to a copy of the history
    /// right before the request. Each client maps it to its own wire shape — Anthropic keeps the
    /// picture past the cache breakpoint, OpenAI-compatible routes send it as the last user turn.
    public static let role = "screen_frame"

    /// Said above the picture, so the model knows the image is the screen it just acted on and
    /// not a file it opened earlier.
    public static let intro = "The screen as it is now, with the real cursor visible:"

    /// The message appended at the tail of a request.
    public static func message(parts: [AIMultimodalPart]) -> AIMessage {
        AIMessage(role: role, multimodalParts: [.text(intro)] + parts)
    }
}
