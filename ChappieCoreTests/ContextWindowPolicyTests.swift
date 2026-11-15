// ContextWindowPolicyTests.swift
// ChappieCoreTests
//
// The window policy exists to keep the cached prefix stable. These tests pin the shape of that
// behaviour: no trim while there is room, a trim back to the limit (not to the allowance), the
// three allowance modes, and an unlimited limit that never trims.

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

    // MARK: - Allowance shape

    @Test("Slack is proportional with a floor of four")
    func slackShape() {
        #expect(ContextWindowPolicy.slack(for: 10) == 4, "the floor applies to small windows")
        #expect(ContextWindowPolicy.slack(for: 30) == 4, "the default window keeps a four-message slack")
        #expect(ContextWindowPolicy.slack(for: 100) == 12)
        #expect(ContextWindowPolicy.slack(for: 1000) == 125)
        #expect(ContextWindowPolicy.slack(for: Int.max) == 0, "unlimited needs no slack")
    }

    @Test("Each mode allows a different amount beyond the limit")
    func allowancePerMode() {
        #expect(ContextWindowPolicy.allowance(limit: 30, mode: .exact) == 30)
        #expect(ContextWindowPolicy.allowance(limit: 30, mode: .slack) == 34)
        #expect(ContextWindowPolicy.allowance(limit: 30, mode: .triple) == 90)
    }

    @Test("An unlimited limit is unlimited in every mode")
    func allowanceUnlimited() {
        for mode in [ContextWindowAllowance.exact, .slack, .triple] {
            #expect(ContextWindowPolicy.allowance(limit: Int.max, mode: mode) == Int.max)
        }
    }

    // MARK: - Exact mode

    @Test("Exact mode cuts as soon as the history outgrows the limit")
    func exactTrimsImmediately() {
        let result = ContextWindowPolicy.trim(history(31), limit: 30, mode: .exact)
        #expect(result.messages.count == 30)
        #expect(result.trimmedFrom == 31)
        #expect(result.messages.last?.contentString == "m30")
    }

    @Test("Exact mode leaves a history at the limit untouched")
    func exactKeepsExactLimit() {
        let input = history(30)
        let result = ContextWindowPolicy.trim(input, limit: 30, mode: .exact)
        #expect(result.messages.count == 30)
        #expect(result.trimmedFrom == nil)
        #expect(contents(result.messages) == contents(input))
    }

    // MARK: - Triple mode

    @Test("Triple mode sends the whole history up to three times the limit")
    func tripleGrowsToTriple() {
        for count in [31, 60, 89, 90] {
            let result = ContextWindowPolicy.trim(history(count), limit: 30, mode: .triple)
            #expect(result.messages.count == count, "\(count) messages must still be sent whole")
            #expect(result.trimmedFrom == nil)
            #expect(result.messages.first?.contentString == "m0", "the prefix must stay identical")
        }
    }

    @Test("Past three times the limit it cuts back to the limit")
    func tripleTrimsBackToLimit() {
        let result = ContextWindowPolicy.trim(history(91), limit: 30, mode: .triple)
        #expect(result.messages.count == 30, "not to the allowance — that would grow the window")
        #expect(result.trimmedFrom == 91)
        #expect(result.messages.first?.contentString == "m61")
        #expect(result.messages.last?.contentString == "m90")
    }

    @Test("Between trims in triple mode the prefix stays identical for many turns")
    func triplePrefixStableAcrossTurns() {
        var messages = history(86)
        #expect(ContextWindowPolicy.trim(messages, limit: 30, mode: .triple).trimmedFrom == nil)

        // Two more turns of two messages each bring the history to exactly the allowance.
        for turn in 1...2 {
            messages.append(AIMessage(role: "user", content: "q\(turn)"))
            messages.append(AIMessage(role: "assistant", content: "a\(turn)"))
        }
        let stillWhole = ContextWindowPolicy.trim(messages, limit: 30, mode: .triple)
        #expect(stillWhole.messages.count == 90, "90 is exactly three times the limit")
        #expect(stillWhole.trimmedFrom == nil)
        #expect(stillWhole.messages.first?.contentString == "m0")

        // The first message past the allowance triggers the cut.
        messages.append(AIMessage(role: "user", content: "one more"))
        let trimmed = ContextWindowPolicy.trim(messages, limit: 30, mode: .triple)
        #expect(trimmed.trimmedFrom == 91)
        #expect(trimmed.messages.count == 30)
    }

    // MARK: - Slack mode (unchanged behaviour)

    @Test("Slack mode is used until the small allowance is exceeded")
    func slackModeStillWorks() {
        for count in 31...34 {
            let result = ContextWindowPolicy.trim(history(count), limit: 30, mode: .slack)
            #expect(result.messages.count == count, "\(count) messages must still be sent whole")
            #expect(result.trimmedFrom == nil)
        }

        let result = ContextWindowPolicy.trim(history(35), limit: 30, mode: .slack)
        #expect(result.messages.count == 30)
        #expect(result.trimmedFrom == 35)
        #expect(result.messages.first?.contentString == "m5", "the newest 30 are kept")
    }

    @Test("The default mode is slack, so existing callers keep their behaviour")
    func defaultModeIsSlack() {
        #expect(ContextWindowPolicy.trim(history(34), limit: 30).trimmedFrom == nil)
        #expect(ContextWindowPolicy.trim(history(35), limit: 30).messages.count == 30)
    }

    // MARK: - Edges

    @Test("A history within the limit is sent untouched")
    func withinLimit() {
        let input = history(20)
        let result = ContextWindowPolicy.trim(input, limit: 30)
        #expect(result.messages.count == 20)
        #expect(result.trimmedFrom == nil)
        #expect(contents(result.messages) == contents(input))
    }

    @Test("Unlimited never trims, in any mode")
    func unlimited() {
        for mode in [ContextWindowAllowance.exact, .slack, .triple] {
            let result = ContextWindowPolicy.trim(history(500), limit: Int.max, mode: mode)
            #expect(result.messages.count == 500)
            #expect(result.trimmedFrom == nil)
        }
    }

    @Test("A limit above the history length changes nothing")
    func limitAboveHistory() {
        let result = ContextWindowPolicy.trim(history(12), limit: 100, mode: .triple)
        #expect(result.messages.count == 12)
        #expect(result.trimmedFrom == nil)
    }

    // MARK: - Cache profile

    @Test("A client that says nothing about caching has no profile")
    func cacheProfileDefault() {
        let a = AIClient(
            endpoint: "https://example.com/v1/chat/completions",
            apiKey: "k",
            modelName: "m"
        )
        #expect(a.promptCacheProfile == nil)
        #expect(a.promptCacheProfile == nil, "the wider allowance needs real cache reads")
    }

    @Test("A caching Anthropic route reports the one-hour TTL")
    func cacheProfileAnthropic() {
        let client = AnthropicClient(
            baseURL: "https://routerai.ru",
            apiKey: "k",
            modelName: "anthropic/claude-sonnet-5.5",
            messagesPath: "/api/v1/messages",
            supportsCaching: true
        )
        let profile = client.promptCacheProfile
        #expect(profile?.ttl == 3600)
    }

    @Test("An Anthropic route without caching has no profile")
    func cacheProfileOff() {
        let client = AnthropicClient(
            baseURL: "https://api.anthropic.com",
            apiKey: "k",
            modelName: "claude-sonnet-5-5"
        )
        #expect(client.promptCacheProfile == nil, "no caching means no reason to overshoot the window")
    }
}
