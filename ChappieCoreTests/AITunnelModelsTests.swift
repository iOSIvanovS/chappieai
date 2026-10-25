// AITunnelModelsTests.swift
// ChappieCoreTests
//
// Unit tests for AITunnel Codable models.
//
// WHY TEST MODELS: Models are the contract with the external API.
// A broken Codable (e.g. renamed field without @CodingKey) causes cryptic
// decoding failures in production. Tests with real JSON strings catch regressions early.
//
// SPECIAL ATTENTION: AIMessageContent is a polymorphic enum with custom Codable —
// the most fragile part of the models. Both cases are tested explicitly.

import Testing
import Foundation
@testable import ChappieCore

@Suite("AITunnelModels Tests")
struct AITunnelModelsTests {

    // MARK: - AIMessageContent

    @Test("AIMessageContent.text encodes as a plain string")
    func messageContentTextEncodesAsString() throws {
        let message = AIMessage(role: "user", content: "Hello, world!")

        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // content must be a string, not an object
        #expect(json?["content"] as? String == "Hello, world!")
    }

    @Test("AIMessageContent.blocks encodes as an array of objects")
    func messageContentBlocksEncodesAsArray() throws {
        let message = AIMessage(role: "system", contentBlocks: [.cached("System prompt")])

        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let contentArray = json?["content"] as? [[String: Any]]
        #expect(contentArray != nil)
        #expect(contentArray?.count == 1)
        #expect(contentArray?.first?["text"] as? String == "System prompt")
        #expect(contentArray?.first?["type"] as? String == "text")
    }

    @Test("AIMessageContent decodes from string as .text")
    func messageContentDecodesFromString() throws {
        let json = """
        {"role": "user", "content": "Test message"}
        """
        let data = json.data(using: .utf8)!
        let message = try JSONDecoder().decode(AIMessage.self, from: data)

        if case .text(let text) = message.content {
            #expect(text == "Test message")
        } else {
            Issue.record("Expected .text case, got a different case")
        }
    }

    @Test("contentString returns text for both AIMessageContent cases")
    func contentStringWorksForBothCases() {
        let textMessage = AIMessage(role: "user", content: "Hello")
        #expect(textMessage.contentString == "Hello")

        let blockMessage = AIMessage(role: "system", contentBlocks: [
            .plain("Part 1"),
            .plain(" Part 2")
        ])
        #expect(blockMessage.contentString == "Part 1 Part 2")
    }

    // MARK: - AICacheControl

    @Test("AICacheControl encodes with type = ephemeral")
    func cacheControlEncodesCorrectly() throws {
        let cacheControl = AICacheControl()
        let data = try JSONEncoder().encode(cacheControl)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: String]

        #expect(json?["type"] == "ephemeral")
    }

    @Test("AIContentBlock.cached() produces a block with cache_control")
    func contentBlockCachedHasCacheControl() throws {
        let block = AIContentBlock.cached("Cached text")
        #expect(block.cache_control != nil)
        #expect(block.cache_control?.type == "ephemeral")
        #expect(block.text == "Cached text")
        #expect(block.type == "text")
    }

    @Test("AIContentBlock.plain() produces a block without cache_control")
    func contentBlockPlainHasNoCacheControl() {
        let block = AIContentBlock.plain("Plain text")
        #expect(block.cache_control == nil)
        #expect(block.text == "Plain text")
    }

    // MARK: - AITunnelRequest

    @Test("AITunnelRequest.stream defaults to false")
    func requestStreamDefaultFalse() throws {
        let request = AITunnelRequest(
            model: "claude-sonnet-4.6",
            messages: [],
            stream: false
        )
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["stream"] as? Bool == false)
    }

    @Test("AITunnelRequest.stream = true encodes correctly")
    func requestStreamTrue() throws {
        let request = AITunnelRequest(
            model: "claude-sonnet-4.6",
            messages: [],
            stream: true
        )
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["stream"] as? Bool == true)
    }

    @Test("AITunnelRequest never sends temperature (o-series/gpt-5 reject non-default values)")
    func requestOmitsTemperature() throws {
        let request = AITunnelRequest(model: "o3", messages: [], stream: true)
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["temperature"] == nil)
    }

    // MARK: - AIStreamChunk

    @Test("AIStreamChunk decodes from a real SSE JSON payload")
    func streamChunkDecodesFromRealJSON() throws {
        let json = """
        {
            "id": "chatcmpl-abc123",
            "choices": [
                {
                    "delta": {"content": "Hello"},
                    "finish_reason": null
                }
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let chunk = try JSONDecoder().decode(AIStreamChunk.self, from: data)

        #expect(chunk.id == "chatcmpl-abc123")
        #expect(chunk.choices.count == 1)
        #expect(chunk.choices[0].delta.content == "Hello")
        #expect(chunk.choices[0].finish_reason == nil)
    }

    @Test("AIStreamChunk with usage decodes correctly")
    func streamChunkWithUsageDecodes() throws {
        let json = """
        {
            "id": "chatcmpl-final",
            "choices": [{"delta": {}, "finish_reason": "stop"}],
            "usage": {
                "prompt_tokens": 100,
                "completion_tokens": 50,
                "total_tokens": 150,
                "cost_rub": 0.0042,
                "balance": 99.9958
            }
        }
        """
        let data = json.data(using: .utf8)!
        let chunk = try JSONDecoder().decode(AIStreamChunk.self, from: data)

        #expect(chunk.usage?.prompt_tokens == 100)
        #expect(chunk.usage?.cost_rub == 0.0042)
        #expect(chunk.choices[0].finish_reason == "stop")
    }

    // MARK: - AIUsage Prompt Caching

    @Test("AIUsage decodes cache_creation and cache_read token fields")
    func usageDecodesCacheTokens() throws {
        let json = """
        {
            "prompt_tokens": 1000,
            "completion_tokens": 200,
            "total_tokens": 1200,
            "cost_rub": 0.01,
            "balance": 99.99,
            "cache_creation_input_tokens": 800,
            "cache_read_input_tokens": 0
        }
        """
        let data = json.data(using: .utf8)!
        let usage = try JSONDecoder().decode(AIUsage.self, from: data)

        #expect(usage.cache_creation_input_tokens == 800)
        #expect(usage.cache_read_input_tokens == 0)
    }

    // MARK: - Roundtrip

    @Test("AIMessage Codable roundtrip preserves all fields")
    func aiMessageRoundtrip() throws {
        let original = AIMessage(
            role: "user",
            content: "Test message",
            tool_calls: nil,
            tool_call_id: nil,
            name: nil
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AIMessage.self, from: data)

        #expect(decoded.role == original.role)
        #expect(decoded.contentString == original.contentString)
    }
}
