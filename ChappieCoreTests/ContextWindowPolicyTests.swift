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

    // MARK: - The anchor (why the window stops sliding)

    // Without an anchor the window slides: 112 messages cut to the newest 30, next turn 114 cut to
    // 30 — the first message moves and the cached prefix dies. Measured live twice at ~84000
    // tokens written and 23.86 RUB per turn. These tests pin the fix.

    @Test("A trimmed window returns an anchor naming the message it starts at")
    func trimReturnsAnchorOfFirstMessage() {
        let result = ContextWindowPolicy.slice(history(91), limit: 30, mode: .triple)
        #expect(result.trimmedFrom == 91)
        #expect(result.messages.first?.contentString == "m61")
        // Index 61 is odd, so this message is the assistant's.
        #expect(result.anchor == WindowAnchor.signature(of: AIMessage(role: "assistant", content: "m61")))
    }

    @Test("Turns after a trim keep the same prefix instead of sliding")
    func anchorStopsSliding() {
        var messages = history(91)
        let first = ContextWindowPolicy.slice(messages, limit: 30, mode: .triple)
        #expect(first.trimmedFrom == 91)
        let anchor = first.anchor
        #expect(anchor != nil)

        // The next turn grows the history by two; the window must start where it started before.
        messages.append(AIMessage(role: "user", content: "q1"))
        messages.append(AIMessage(role: "assistant", content: "a1"))

        let second = ContextWindowPolicy.slice(messages, limit: 30, mode: .triple, anchorSignature: anchor)
        #expect(second.trimmedFrom == nil, "the window has not outgrown the allowance yet")
        #expect(second.messages.first?.contentString == "m61", "the window still starts where it did")
        #expect(Array(contents(second.messages).prefix(first.messages.count)) == contents(first.messages),
                "the old window must still be a prefix: that is the only thing the cache compares")

        // And a third turn still starts at the same message.
        messages.append(AIMessage(role: "user", content: "q2"))
        let third = ContextWindowPolicy.slice(messages, limit: 30, mode: .triple, anchorSignature: second.anchor)
        #expect(third.messages.first?.contentString == "m61")
    }

    @Test("The window grows from its anchored start until the allowance runs out")
    func anchoredWindowGrows() {
        var messages = history(91)
        var anchor = ContextWindowPolicy.slice(messages, limit: 30, mode: .triple).anchor

        // Fill up to the 90-message allowance the window now spans, measured from the anchor.
        var count = 30
        while count < 90 {
            messages.append(AIMessage(role: "user", content: "fill\(count)"))
            count += 1
        }
        #expect(messages.count == 151, "91 original plus 60 fills")

        let full = ContextWindowPolicy.slice(messages, limit: 30, mode: .triple, anchorSignature: anchor)
        #expect(full.messages.count == 90)
        #expect(full.trimmedFrom == nil, "exactly at the allowance is still sent whole")
        #expect(full.messages.first?.contentString == "m61")

        // One more message and the window is re-cut, producing a new anchor.
        messages.append(AIMessage(role: "user", content: "one past"))
        let recut = ContextWindowPolicy.slice(messages, limit: 30, mode: .triple, anchorSignature: anchor)
        #expect(recut.trimmedFrom == 152)
        #expect(recut.messages.count == 30)
        #expect(recut.anchor != anchor, "a re-cut establishes a new starting point")
        anchor = recut.anchor

        // And the new anchor holds the prefix steady again: one more message, same start.
        messages.append(AIMessage(role: "user", content: "after recut"))
        let after = ContextWindowPolicy.slice(messages, limit: 30, mode: .triple, anchorSignature: anchor)
        #expect(after.messages.first?.contentString == recut.messages.first?.contentString)
        #expect(after.trimmedFrom == nil)
    }

    @Test("An unknown anchor falls back to the newest messages")
    func unknownAnchorFallsBack() {
        let result = ContextWindowPolicy.slice(
            history(120), limit: 30, mode: .triple,
            anchorSignature: WindowAnchor.signature(of: AIMessage(role: "user", content: "not here"))
        )
        #expect(result.messages.count == 30)
        #expect(result.trimmedFrom == 120, "nothing matched, so the usual cut applies")
        #expect(result.messages.first?.contentString == "m90")
    }

    @Test("An anchor too close to the end is ignored, so a window is never starved")
    func nearEndAnchorIsIgnored() {
        // The anchor names the very last message: honouring it would send one message.
        let last = AIMessage(role: "assistant", content: "m119")
        let result = ContextWindowPolicy.slice(
            history(120), limit: 30, mode: .triple,
            anchorSignature: WindowAnchor.signature(of: last)
        )
        #expect(result.messages.count == 30)
        #expect(result.messages.first?.contentString == "m90")
    }

    @Test("Repeated text is told apart by copy number, so the window does not slide on duplicates")
    func duplicateTextKeepsSameStart() {
        // An assistant answering "ok" twenty times is an ordinary conversation. A plain
        // role-and-text signature would match a different copy each turn and re-cut the window
        // every time — the sliding window would come straight back.
        var messages: [AIMessage] = []
        for index in 0..<100 {
            messages.append(AIMessage(role: "user", content: "q\(index)"))
            messages.append(AIMessage(role: "assistant", content: "ok"))
        }

        let first = ContextWindowPolicy.slice(messages, limit: 30, mode: .triple)
        #expect(first.trimmedFrom == 200)
        // The cut lands on an assistant "ok" (200 - 30 = 170, even index is a user turn, so 170 is
        // "q85"; the copy number is what matters here).
        let anchor = first.anchor

        messages.append(AIMessage(role: "user", content: "next"))
        messages.append(AIMessage(role: "assistant", content: "ok"))

        let second = ContextWindowPolicy.slice(messages, limit: 30, mode: .triple, anchorSignature: anchor)
        #expect(second.trimmedFrom == nil, "no re-cut just because the same text appeared again")
        #expect(second.messages.first?.contentString == first.messages.first?.contentString)
        #expect(Array(contents(second.messages).prefix(first.messages.count)) == contents(first.messages))

        // One more turn, still standing on the same anchored message.
        messages.append(AIMessage(role: "user", content: "next again"))
        let third = ContextWindowPolicy.slice(messages, limit: 30, mode: .triple, anchorSignature: second.anchor)
        #expect(third.trimmedFrom == nil)
        #expect(third.messages.first?.contentString == first.messages.first?.contentString)
    }

    @Test("Copy numbers make otherwise identical signatures distinct")
    func signaturesDistinguishCopies() {
        let messages = [
            AIMessage(role: "assistant", content: "ok"),
            AIMessage(role: "assistant", content: "ok"),
            AIMessage(role: "assistant", content: "ok")
        ]
        let signatures = WindowAnchor.signatures(for: messages)
        #expect(Set(signatures).count == 3, "three copies must be three distinct anchors")
        #expect(signatures[1].hasSuffix("#1"))
        #expect(signatures[2].hasSuffix("#2"))
    }

    @Test("Appending messages never renumbers existing signatures")
    func appendingKeepsSignatures() {
        // This is the guarantee the anchor relies on between two turns.
        let original = history(40)
        let before = WindowAnchor.signatures(for: original)

        var grown = original
        grown.append(AIMessage(role: "assistant", content: "new reply"))
        let after = WindowAnchor.signatures(for: grown)

        #expect(Array(after.prefix(before.count)) == before)
    }

    @Test("Prepended older chunks do not disturb the anchor")
    func prependedChunksKeepAnchor() {
        // The app prepends older history chunks between turns, so every index moves. An index-based
        // anchor would point at a different message; a signature-based one still finds its message.
        var messages = history(91)
        let anchor = ContextWindowPolicy.slice(messages, limit: 30, mode: .triple).anchor

        let older = (0..<500).map { AIMessage(role: "user", content: "old\($0)") }
        messages = older + messages

        let result = ContextWindowPolicy.slice(messages, limit: 30, mode: .triple, anchorSignature: anchor)
        #expect(result.messages.first?.contentString == "m61", "the window still starts at m61")
        #expect(result.messages.count == 30, "and it does not sprawl over the prepended chunk")
    }

    @Test("A history that fits reports an anchor, so the window can start growing from it")
    func fittingHistoryHasAnchor() {
        let result = ContextWindowPolicy.slice(history(20), limit: 30, mode: .triple)
        #expect(result.trimmedFrom == nil)
        #expect(result.anchor == WindowAnchor.signature(of: AIMessage(role: "user", content: "m0")))
    }

    // MARK: - Cache warmth threshold

    // The allowance only widens while the prefix is still readable. These pin the boundary: the
    // safe margin, the exact TTL boundary, and the two ways of having no usable profile.

    private let oneHour = PromptCacheProfile(ttl: 3600)

    @Test("No recorded request means a cold cache")
    func warmthNoRecord() {
        let warm = ContextWindowPolicy.cacheIsWarm(
            lastRequestAt: nil, now: Date(), profile: oneHour
        )
        #expect(!warm)
    }

    @Test("No profile means a cold cache, however recent the request")
    func warmthNoProfile() {
        let warm = ContextWindowPolicy.cacheIsWarm(
            lastRequestAt: Date(), now: Date(), profile: nil
        )
        #expect(!warm, "a route without a cache never earns the wider allowance")
    }

    @Test("A turn two minutes later still finds the prefix warm")
    func warmthRecentRequest() {
        let now = Date()
        let warm = ContextWindowPolicy.cacheIsWarm(
            lastRequestAt: now.addingTimeInterval(-120), now: now, profile: oneHour
        )
        #expect(warm)
    }

    @Test("The margin makes the cache cold before the nominal TTL runs out")
    func warmthMargin() {
        let now = Date()
        // 54 minutes is exactly 90% of the hour.
        let atMargin = ContextWindowPolicy.cacheIsWarm(
            lastRequestAt: now.addingTimeInterval(-3600 * 0.9), now: now, profile: oneHour
        )
        #expect(!atMargin, "a request starting at the margin cannot count on the prefix")

        let justInside = ContextWindowPolicy.cacheIsWarm(
            lastRequestAt: now.addingTimeInterval(-3600 * 0.9 + 1), now: now, profile: oneHour
        )
        #expect(justInside)
    }

    @Test("After the TTL the cache is cold")
    func warmthExpired() {
        let now = Date()
        let warm = ContextWindowPolicy.cacheIsWarm(
            lastRequestAt: now.addingTimeInterval(-3601), now: now, profile: oneHour
        )
        #expect(!warm)
    }

    @Test("A different TTL moves the boundary, so the margin is not hardcoded to an hour")
    func warmthCustomTTL() {
        let now = Date()
        let fiveMinutes = PromptCacheProfile(ttl: 300)
        #expect(ContextWindowPolicy.cacheIsWarm(
            lastRequestAt: now.addingTimeInterval(-240), now: now, profile: fiveMinutes
        ))
        #expect(!ContextWindowPolicy.cacheIsWarm(
            lastRequestAt: now.addingTimeInterval(-300), now: now, profile: fiveMinutes
        ))
    }

    // MARK: - Cache profile

    // WHY EVERY TEST HERE GOES THROUGH `any AIClientProtocol`:
    // The orchestrator holds the protocol type, not the concrete client. An implementation that
    // only exists in a protocol extension — with the protocol itself not declaring the member —
    // is dispatched statically, so the extension's nil wins at runtime no matter what the
    // concrete client says. Testing the concrete client alone hides exactly that failure: it
    // passed here while the app logged `slack` on a cache-reading route. These tests ask the
    // question the orchestrator actually asks.

    @Test("An OpenAI-compatible client has no cache profile")
    func cacheProfileDefault() {
        let a: any AIClientProtocol = AIClient(
            endpoint: "https://example.com/v1/chat/completions",
            apiKey: "k",
            modelName: "m"
        )
        #expect(a.promptCacheProfile == nil, "the wider allowance needs real cache reads")
    }

    @Test("A caching Anthropic route reports the one-hour TTL through the protocol")
    func cacheProfileAnthropic() {
        let client: any AIClientProtocol = AnthropicClient(
            baseURL: "https://routerai.ru",
            apiKey: "k",
            modelName: "anthropic/claude-sonnet-5.5",
            messagesPath: "/api/v1/messages",
            supportsCaching: true
        )
        #expect(client.promptCacheProfile?.ttl == 3600)
    }

    @Test("An Anthropic route without caching has no profile")
    func cacheProfileOff() {
        let client: any AIClientProtocol = AnthropicClient(
            baseURL: "https://api.anthropic.com",
            apiKey: "k",
            modelName: "claude-sonnet-5-5"
        )
        #expect(client.promptCacheProfile == nil, "no caching means no reason to overshoot the window")
    }

    @Test("The profile is a protocol requirement, so it is dispatched dynamically")
    func cacheProfileIsDynamic() {
        // Two clients behind the same existential type must answer differently. If the member
        // were only an extension default, both would answer nil and this would fail.
        let clients: [any AIClientProtocol] = [
            AnthropicClient(
                baseURL: "https://routerai.ru",
                apiKey: "k",
                modelName: "anthropic/claude-sonnet-5.5",
                messagesPath: "/api/v1/messages",
                supportsCaching: true
            ),
            AIClient(endpoint: "https://example.com/v1/chat/completions", apiKey: "k", modelName: "m")
        ]
        #expect(clients.map(\.promptCacheProfile?.ttl) == [3600, nil])
    }
}
