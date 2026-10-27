// MessageTimestampTests.swift
// ChappieCoreTests
//
// Labels are deterministic, client-computed, and only on user messages.

import Testing
import Foundation
@testable import ChappieCore

@Suite("MessageTimestamp")
struct MessageTimestampTests {

    private let moscow = TimeZone(secondsFromGMT: 3 * 3600)!
    // 2026-10-27 12:03:00 UTC = 15:03 in +03:00
    private let base = Date(timeIntervalSince1970: 1_793_102_580)

    private func entry(_ isUser: Bool, _ offset: TimeInterval?) -> MessageTimestampEntry {
        MessageTimestampEntry(id: UUID(), isUser: isUser, createdAt: offset.map { base.addingTimeInterval($0) })
    }

    @Test("Stamp is full: date, time, offset")
    func stampFormat() {
        #expect(MessageTimestamp.stamp(base, timeZone: moscow) == "2026-10-27 15:03 +03:00")
        let ny = TimeZone(secondsFromGMT: -(5 * 3600 + 1800))!
        #expect(MessageTimestamp.stamp(base, timeZone: ny) == "2026-10-27 06:33 -05:30")
    }

    @Test("Duration uses the two most significant units")
    func durations() {
        #expect(MessageTimestamp.duration(4 * 60 + 30) == "4m")
        #expect(MessageTimestamp.duration(3600) == "1h")
        #expect(MessageTimestamp.duration(23 * 3600 + 10 * 60) == "23h 10m")
        #expect(MessageTimestamp.duration(2 * 86400 + 3 * 3600 + 59) == "2d 3h")
        #expect(MessageTimestamp.duration(86400) == "1d")
    }

    @Test("First message: bare stamp, no gap")
    func firstMessage() {
        let first = entry(true, 0)
        let labels = MessageTimestamp.labels(for: [first], timeZone: moscow)
        #expect(labels[first.id] == "[2026-10-27 15:03 +03:00]")
    }

    @Test("Gap and previous run duration are both reported")
    func gapAndRun() {
        let q1 = entry(true, 0)
        let a1 = entry(false, 4 * 60)            // run took 4m
        let q2 = entry(true, 4 * 60 + 23 * 3600) // user answered 23h later
        let labels = MessageTimestamp.labels(for: [q1, a1, q2], timeZone: moscow)
        #expect(labels[q2.id] == "[2026-10-28 14:07 +03:00 · 23h since previous message · previous reply took 4m]")
        #expect(labels[a1.id] == nil)
    }

    @Test("Gaps under a minute are not reported")
    func shortGapOmitted() {
        let q1 = entry(true, 0)
        let a1 = entry(false, 20)
        let q2 = entry(true, 50)
        let labels = MessageTimestamp.labels(for: [q1, a1, q2], timeZone: moscow)
        #expect(labels[q2.id] == "[2026-10-27 15:03 +03:00]")
    }

    @Test("Messages without a creation time are skipped and produce no run duration")
    func legacyMessages() {
        let q1 = entry(true, nil)
        let a1 = entry(false, nil)
        let q2 = entry(true, 100)
        let labels = MessageTimestamp.labels(for: [q1, a1, q2], timeZone: moscow)
        #expect(labels[q1.id] == nil)
        #expect(labels[q2.id] == "[2026-10-27 15:04 +03:00]")
    }

    @Test("Run duration needs a user -> assistant pair")
    func runNeedsPair() {
        let q1 = entry(true, 0)
        let q2 = entry(true, 600)
        let labels = MessageTimestamp.labels(for: [q1, q2], timeZone: moscow)
        #expect(labels[q2.id] == "[2026-10-27 15:13 +03:00 · 10m since previous message]")
    }

    @Test("Same input gives the same label (cache stability)")
    func deterministic() {
        let q1 = entry(true, 0)
        let a1 = entry(false, 300)
        let q2 = entry(true, 9000)
        let list = [q1, a1, q2]
        #expect(MessageTimestamp.labels(for: list, timeZone: moscow) == MessageTimestamp.labels(for: list, timeZone: moscow))
    }

    @Test("prefixed puts the label on its own first line")
    func prefixing() {
        #expect(MessageTimestamp.prefixed("hi", with: "[x]") == "[x]\nhi")
        #expect(MessageTimestamp.prefixed("", with: "[x]") == "[x]")
        #expect(MessageTimestamp.prefixed("hi", with: nil) == "hi")
    }
}
