// ComputerUseElementStore.swift
// ChappieCore
//
// WHY THIS FILE:
// Element numbers span two tool calls: computer_screenshot prints them, computer_click consumes
// them. The model only ever holds the text of a result, so the frames behind each number must be
// remembered here between calls.
//
// WHY THE NUMBERS ARE CLEARED:
// A number is a promise about ONE picture. Once the layout can shift — a click, a scroll, a
// keystroke — the same number may label something else, and clicking it would land on whatever
// moved into its place. Forgetting the numbers is the safe outcome: the model asks for a fresh
// screenshot instead of clicking into the void.

import Foundation

/// One numbered screenshot: what the model saw and the frames behind every number.
struct MarkedScreenshot: Equatable, Sendable {
    /// 1-based, printed in the tool result so a later message can name the picture it used.
    let id: Int
    /// Application whose window was read — for messages only.
    let applicationName: String
    /// That application's process, so a later action can activate exactly this app. Activating by
    /// click point would pick whatever window is on top there, which may well be Chappie itself.
    let pid: pid_t?
    /// In numbering order. Empty when the app reported nothing clickable.
    let marks: [ElementMark]

    init(id: Int, applicationName: String, pid: pid_t? = nil, marks: [ElementMark]) {
        self.id = id
        self.applicationName = applicationName
        self.pid = pid
        self.marks = marks
    }

    /// The element behind a number the model passed back, or nil if there is no such number.
    func element(number: Int) -> ElementMark? {
        marks.first { $0.number == number }
    }
}

/// Holds the numbered screenshots of the current computer-use session.
/// A lock rather than an actor: it is touched from MainActor screenshot code and from the
/// tool actor, and callers only need a value in and a value out.
final class MarkedScreenshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: MarkedScreenshot?
    private var nextID = 1

    init() {}

    /// Stores the numbers of a new screenshot and returns it with its id.
    @discardableResult
    func record(applicationName: String, pid: pid_t? = nil, marks: [ElementMark]) -> MarkedScreenshot {
        lock.lock()
        defer { lock.unlock() }
        let shot = MarkedScreenshot(id: nextID, applicationName: applicationName, pid: pid, marks: marks)
        nextID += 1
        stored = shot
        return shot
    }

    func latest() -> MarkedScreenshot? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// Drops the numbers: whatever they described is no longer guaranteed to be on screen.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        stored = nil
    }
}
