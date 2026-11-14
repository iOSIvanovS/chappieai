import Testing
import Foundation
@testable import ChappieCore

// Consecutive same-role messages must merge by BLOCKS, not by text.
//
// WHY THIS SUITE EXISTS: Anthropic rejects two consecutive messages of the same role, so a history
// with two parallel tool calls (two `tool` rows in a row) has to be merged. Flattening a tool_result
// into text drops its tool_use_id, and the request still returns HTTP 200 — the model simply loses
// which output belongs to which call and answers something wrong. A silent wrong answer is worse
// than an error, so this is pinned by tests.
@Suite("Anthropic message conversion")
struct AnthropicMessageConversionTests {

    private func client(caching: Bool = false) -> AnthropicClient {
        AnthropicClient(
            baseURL: "https://example.invalid",
            apiKey: "test-key",
            modelName: "claude-test",
            supportsCaching: caching
        )
    }

    private func toolRow(id: String, output: String) -> AIMessage {
        AIMessage(role: "tool", content: output, tool_call_id: id)
    }

    /// Content blocks of one message, whichever shape the content took.
    static func blocks(in message: AnthropicMessage) -> [AnthropicContentBlock] {
        switch message.content {
        case .blocks(let blocks):
            return blocks
        case .text(let text):
            return text.isEmpty ? [] : [AnthropicContentBlock(type: "text", text: text)]
        case .toolResult(let result):
            return [AnthropicContentBlock(type: result.type, text: nil, toolResult: result)]
        }
    }

    /// Tool results of one message, whichever shape the content took.
    static func toolResults(in message: AnthropicMessage) -> [AnthropicToolResultContent] {
        switch message.content {
        case .toolResult(let result):
            return [result]
        case .blocks(let blocks):
            return blocks.compactMap(\.toolResult)
        case .text:
            return []
        }
    }

    private func assistantCall(id: String, name: String) -> AIMessage {
        AIMessage(
            role: "assistant",
            tool_calls: [
                AIToolCall(
                    id: id,
                    type: "function",
                    function: .init(name: name, arguments: #"{"project":"Chappie"}"#)
                )
            ]
        )
    }

    @Test("Two parallel tool results keep both tool_use_ids")
    func parallelToolResultsKeepIds() {
        let history: [AIMessage] = [
            AIMessage(role: "user", content: "check both projects"),
            assistantCall(id: "toolu_a", name: "git_status"),
            assistantCall(id: "toolu_b", name: "git_status"),
            toolRow(id: "toolu_a", output: "clean"),
            toolRow(id: "toolu_b", output: "dirty")
        ]

        let converted = client().buildAnthropicMessages(from: history)

        // the two tool rows must end up in ONE user message, not two
        let userMessagesWithResults = converted.filter { message in
            Self.toolResults(in: message).isEmpty == false
        }
        #expect(userMessagesWithResults.count == 1, "the two tool rows must be one message")

        let ids = converted.flatMap { Self.toolResults(in: $0).map(\.toolUseId) }
        #expect(ids == ["toolu_a", "toolu_b"], "both ids survive, in order")
    }

    @Test("Merged tool results stay structured, not flattened into text")
    func mergedToolResultsStayStructured() {
        let history: [AIMessage] = [
            assistantCall(id: "toolu_a", name: "git_status"),
            assistantCall(id: "toolu_b", name: "git_status"),
            toolRow(id: "toolu_a", output: "clean"),
            toolRow(id: "toolu_b", output: "dirty")
        ]

        let converted = client().buildAnthropicMessages(from: history)

        for message in converted {
            if case .blocks(let blocks) = message.content {
                for block in blocks where block.type == "tool_result" {
                    // a block carrying a tool_result must have no text — otherwise it was flattened
                    #expect(block.text == nil)
                    #expect(block.toolResult != nil)
                }
            }
        }

        // no message in the whole request may be a plain-text "clean" / "dirty" row
        let plainText = converted.compactMap { message -> String? in
            if case .text(let text) = message.content { return text }
            return nil
        }
        #expect(!plainText.contains("clean"))
        #expect(!plainText.contains("dirty"))
    }

    @Test("No two consecutive messages share a role")
    func noConsecutiveSameRole() {
        let history: [AIMessage] = [
            AIMessage(role: "user", content: "one"),
            AIMessage(role: "user", content: "two"),
            assistantCall(id: "toolu_a", name: "git_status"),
            toolRow(id: "toolu_a", output: "clean")
        ]

        let converted = client().buildAnthropicMessages(from: history)

        var previous: String?
        for message in converted {
            #expect(message.role != previous, "roles must alternate")
            previous = message.role
        }
    }

    @Test("An assistant text block before tool calls is preserved")
    func assistantTextBeforeToolCallsSurvives() {
        let history: [AIMessage] = [
            AIMessage(
                role: "assistant",
                content: "Checking now.",
                tool_calls: [
                    AIToolCall(
                        id: "toolu_a",
                        type: "function",
                        function: .init(name: "git_status", arguments: #"{"project":"Chappie"}"#)
                    )
                ]
            )
        ]

        let converted = client().buildAnthropicMessages(from: history)

        guard case .blocks(let blocks) = converted.first?.content else {
            Issue.record("expected blocks")
            return
        }
        #expect(blocks.first?.type == "text")
        #expect(blocks.first?.text == "Checking now.")
        #expect(blocks.last?.type == "tool_use")
        #expect(blocks.last?.id == "toolu_a")
    }

    @Test("System messages are dropped, not merged into the conversation")
    func systemMessageDropped() {
        let history: [AIMessage] = [
            AIMessage(role: "system", content: "you are helpful"),
            AIMessage(role: "user", content: "hi")
        ]

        let converted = client().buildAnthropicMessages(from: history)

        #expect(converted.count == 1)
        #expect(converted.first?.role == "user")
    }

    @Test("Cache breakpoints: one on the system block, one on the last message")
    func cacheBreakpointsPlaced() {
        let history: [AIMessage] = [
            AIMessage(role: "user", content: "first"),
            AIMessage(role: "assistant", content: "answer"),
            AIMessage(role: "user", content: "second")
        ]

        // caching off: no new fields anywhere, so a strict provider sees nothing unusual
        let plainClient = client(caching: false)
        let plainMessages = plainClient.buildAnthropicMessages(from: history)
        let plainBreakpoints = plainClient.applyingCacheBreakpoints(to: plainMessages)
        for message in plainBreakpoints {
            #expect(Self.toolResults(in: message).allSatisfy { $0.cacheControl == nil })
            for block in Self.blocks(in: message) {
                #expect(block.cacheControl == nil)
            }
        }
        #expect(plainClient.buildSystemBlocks("system")?.first?.cacheControl == nil)

        // caching on: the system block carries a breakpoint
        let cachedClient = client(caching: true)
        let systemBlocks = cachedClient.buildSystemBlocks("system")
        #expect(systemBlocks?.count == 1)
        #expect(systemBlocks?.first?.cacheControl != nil)

        // and the tail of the last message carries the second one
        let cachedMessages = cachedClient.applyingCacheBreakpoints(
            to: cachedClient.buildAnthropicMessages(from: history)
        )
        let lastBlocks = Self.blocks(in: cachedMessages.last!)
        #expect(lastBlocks.last?.cacheControl != nil)

        // nothing else in the request got a breakpoint — two breakpoints per request, not per block
        let totalBreakpoints = cachedMessages.reduce(0) { sum, message in
            sum + Self.blocks(in: message).filter { $0.cacheControl != nil }.count
        }
        #expect(totalBreakpoints == 1)
    }
}
