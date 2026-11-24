import Testing
import Foundation
@testable import ChappieCore

// The live screen frame is the one thing in a computer-use turn that changes on every step.
//
// WHY THESE TESTS EXIST: the frame used to live in the message history, and every new screenshot
// replaced the previous one in place. The replacement sits INSIDE the cached prefix, so the prefix
// no longer matched and the provider rewrote all of it — measured on RouterAI as 15% cache read and
// ~50k tokens written per step. The fix is structural: the frame is appended after the cache
// breakpoint, and the history stays append-only. These tests pin that structure, because it is
// invisible in the UI and a future refactor could quietly reintroduce the cost.
@Suite("Live screen frame placement")
struct ScreenFramePlacementTests {

    private func client(caching: Bool = true) -> AnthropicClient {
        AnthropicClient(
            baseURL: "https://example.invalid",
            apiKey: "test-key",
            modelName: "claude-test",
            supportsCaching: caching
        )
    }

    private func assistantCall(id: String, name: String) -> AIMessage {
        AIMessage(
            role: "assistant",
            tool_calls: [
                AIToolCall(
                    id: id,
                    type: "function",
                    function: .init(name: name, arguments: #"{"monitor":0}"#)
                )
            ]
        )
    }

    private func toolRow(id: String, output: String) -> AIMessage {
        AIMessage(role: "tool", content: output, tool_call_id: id)
    }

    private func frame(_ payload: String) -> AIMessage {
        ScreenFrame.message(parts: [.imageURL("data:image/jpeg;base64,\(payload)")])
    }

    private var historyBeforeFrame: [AIMessage] {
        [
            AIMessage(role: "user", content: "click the blue square"),
            assistantCall(id: "toolu_a", name: "computer_screenshot"),
            toolRow(id: "toolu_a", output: "Monitor 0 of 1. Cursor at (10, 20).")
        ]
    }

    private static func blocks(in message: AnthropicMessage) -> [AnthropicContentBlock] {
        switch message.content {
        case .blocks(let blocks): return blocks
        case .text(let text): return text.isEmpty ? [] : [AnthropicContentBlock(type: "text", text: text)]
        case .toolResult(let result): return [AnthropicContentBlock(type: result.type, text: nil, toolResult: result)]
        }
    }

    private func encoded(_ block: AnthropicContentBlock) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(block) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    @Test("The breakpoint lands on the last prefix block, never on the screen picture")
    func breakpointStaysBeforeTheFrame() {
        let cached = client()
        let messages = cached.applyingCacheBreakpoints(
            to: cached.buildAnthropicMessages(from: historyBeforeFrame + [frame("AAAA")])
        )

        guard let last = messages.last, case .blocks(let blocks) = last.content else {
            Issue.record("expected the frame to merge into one trailing user turn")
            return
        }

        // tool_result, then the intro line, then the picture
        #expect(blocks.count == 3)
        #expect(blocks[0].toolResult != nil)
        #expect(blocks[0].cacheControl != nil, "the prefix ends at the tool result")
        #expect(blocks[1].cacheControl == nil, "the intro line is part of the frame")
        #expect(blocks[2].cacheControl == nil, "the picture must stay outside the cached prefix")
        #expect(blocks[2].source != nil)
        #expect(blocks[2].isScreenFrame)
    }

    @Test("A different screenshot leaves the cached prefix byte-identical")
    func prefixIsIdenticalAcrossFrameChanges() {
        let cached = client()

        /// Everything the provider may keep, encoded exactly as it goes on the wire.
        func cachedPrefix(_ payload: String) -> String {
            let messages = cached.applyingCacheBreakpoints(
                to: cached.buildAnthropicMessages(from: historyBeforeFrame + [frame(payload)])
            )
            var parts: [String] = []
            for message in messages {
                for block in Self.blocks(in: message) {
                    parts.append(encoded(block))
                    if block.cacheControl != nil {
                        return parts.joined(separator: "\n")
                    }
                }
            }
            return parts.joined(separator: "\n")
        }

        let first = cachedPrefix("FIRST")
        #expect(!first.isEmpty)
        #expect(first == cachedPrefix("SECOND"),
                "a new picture must not invalidate what the provider already cached")
    }

    @Test("With caching off nothing changes for a strict provider")
    func cachingOffLeavesNoBreakpoints() {
        let plain = client(caching: false)
        let messages = plain.applyingCacheBreakpoints(
            to: plain.buildAnthropicMessages(from: historyBeforeFrame + [frame("AAAA")])
        )
        for message in messages {
            for block in Self.blocks(in: message) {
                #expect(block.cacheControl == nil)
            }
        }
    }

    @Test("An OpenAI-compatible route sees the frame as a plain last user turn")
    func openAIRouteSeesUserTurn() {
        // supportsCaching is what keeps pictures on this route: a strict provider
        // (Groq, Ollama) drops every image by design, frame or not.
        let openAI = AIClient(
            endpoint: "https://example.invalid/v1/chat/completions",
            apiKey: "test-key",
            modelName: "test-model",
            supportsCaching: true
        )
        let messages = openAI.buildMessages(
            systemPrompt: "system",
            chatHistory: historyBeforeFrame + [frame("AAAA")]
        )

        #expect(messages.first?.role == "system")
        #expect(messages.count == 5)
        #expect(messages.last?.role == "user", "an internal role would be rejected on the wire")
        #expect(messages.last?.multimodalParts?.isEmpty == false)
    }

    @Test("Only the frame is marked, a document picture is not")
    func documentPicturesStayCacheable() {
        let cached = client()
        let history: [AIMessage] = [
            AIMessage(role: "user", content: "read it"),
            AIMessage(role: "tool", content: "document text", tool_call_id: "toolu_a"),
            AIMessage(role: "user", multimodalParts: [
                .text("Images contained in the document"),
                .imageURL("data:image/png;base64,DOC")
            ])
        ]

        let messages = cached.applyingCacheBreakpoints(to: cached.buildAnthropicMessages(from: history))
        let allBlocks = messages.flatMap(Self.blocks)

        #expect(allBlocks.allSatisfy { !$0.isScreenFrame })
        // a document picture sits in the history and is therefore part of the cached prefix
        #expect(allBlocks.last?.cacheControl != nil)
        #expect(allBlocks.last?.source != nil)
    }
}
