// ContextWindowPolicyTests.swift
// ChappieCoreTests
//
// The window policy exists to keep the cached prefix stable. These tests pin the shape of that
// behaviour: no trim while there is room, a trim back to the limit (not to limit + slack), and an
// unlimited limit that never trims.

import Foundation
import Testing
@testable import ChappieCore

@Suite("Context window policy")
struct ContextWindowPolicyTests {

    private func history(_ count: Int) -> [AIMessage] {
        (0..<count).map { AIMessage(role: $0 % 2 == 0 ? "user" : "assistant", content: "m\($0)") }
    }

    private func contents(_ messages: [AIMessage]) -> [String] {
        messages.compactMap(\.contentString)
    }

    @Test("Slack is proportional with a floor of four")
    func slackShape() {
        #expect(ContextWindowPolicy.slack(for: 10) == 4, "the floor applies to small windows")
        #expect(ContextWindowPolicy.slack(for: 30) == 4, "the default window keeps a four-message slack")
        #expect(ContextWindowPolicy.slack(for: 100) == 12)
        #expect(ContextWindowPolicy.slack(for: 1000) == 125)
        #expect(ContextWindowPolicy.slack(for: Int.max) == 0, "unlimited needs no slack")
    }

    @Test("A history within the limit is sent untouched")
    func withinLimit() {
        let input = history(20)
        let result = ContextWindowPolicy.trim(input, limit: 30)
        #expect(result.messages.count == 20)
        #expect(result.trimmedFrom == nil)
        #expect(contents(result.messages) == contents(input))
    }

    @Test("The slack is actually used: the next few messages do not evict the oldest")
    func growsIntoSlack() {
        for count in 31...34 {
            let result = ContextWindowPolicy.trim(history(count), limit: 30)
            #expect(result.messages.count == count, "\(count) messages must still be sent whole")
            #expect(result.trimmedFrom == nil)
            #expect(result.messages.first?.contentString == "m0", "the prefix must stay identical")
        }
    }

    @Test("Past the slack it cuts back to the limit, not to limit plus slack")
    func trimsToLimit() {
        let result = ContextWindowPolicy.trim(history(35), limit: 30)
        #expect(result.messages.count == 30)
        #expect(result.trimmedFrom == 35)
        #expect(result.messages.first?.contentString == "m5", "the newest 30 are kept")
        #expect(result.messages.last?.contentString == "m34")
    }

    @Test("Between trims the prefix is byte-identical, which is what the cache reads")
    func prefixStableBetweenTrims() {
        var messages = history(34)
        #expect(ContextWindowPolicy.trim(messages, limit: 30).trimmedFrom == nil)

        messages.append(AIMessage(role: "user", content: "next"))
        messages.append(AIMessage(role: "assistant", content: "answer"))
        let trimmed = ContextWindowPolicy.trim(messages, limit: 30)
        #expect(trimmed.messages.count == 30, "36 messages are past 34, so the cut happens")
    }

    @Test("Unlimited never trims")
    func unlimited() {
        let input = history(500)
        let result = ContextWindowPolicy.trim(input, limit: Int.max)
        #expect(result.messages.count == 500)
        #expect(result.trimmedFrom == nil)
    }

    @Test("A limit above the history length changes nothing")
    func limitAboveHistory() {
        let result = ContextWindowPolicy.trim(history(12), limit: 100)
        #expect(result.messages.count == 12)
        #expect(result.trimmedFrom == nil)
    }
}
