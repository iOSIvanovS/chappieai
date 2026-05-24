// AITunnelModelsTests.swift
// ChappieCore/Tests/ChappieCoreTests
//
// ВАЖНО: Этот файл синхронизирован с ChappieCoreTests/AITunnelModelsTests.swift
// в корне проекта. Package.swift запускает тесты именно отсюда (path: "Tests/ChappieCoreTests").
// Тестплан Xcode (ChappieCoreTests.xctestplan) запускает тесты из корневого ChappieCoreTests/.
// Оба набора должны быть идентичны.
//
// ЗАЧЕМ ТЕСТИРОВАТЬ МОДЕЛИ:
// Модели — это контракт с внешним API. Если мы сломаем Codable (например, переименуем
// поле без @CodingKey), запросы к API начнут падать с cryptic ошибками декодирования.
// Тесты с реальными JSON-строками защищают от таких регрессий.
//
// ОСОБОЕ ВНИМАНИЕ: AIMessageContent — полиморфный enum с кастомным Codable.
// Это самое хрупкое место в моделях — тестируем оба кейса явно.

import Testing
import Foundation
@testable import ChappieCore

@Suite("AITunnelModels Tests")
struct AITunnelModelsTests {

    // MARK: - AIMessageContent

    /// Кодирование .text → простая JSON-строка (не объект).
    @Test("AIMessageContent.text кодируется как строка")
    func messageContentTextEncodesAsString() throws {
        let message = AIMessage(role: "user", content: "Hello, world!")

        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // content должен быть строкой, не объектом
        #expect(json?["content"] as? String == "Hello, world!")
    }

    /// Кодирование .blocks → массив объектов с полем "type" и "text".
    @Test("AIMessageContent.blocks кодируется как массив объектов")
    func messageContentBlocksEncodesAsArray() throws {
        let message = AIMessage(role: "system", contentBlocks: [.cached("System prompt")])

        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // content должен быть массивом
        let contentArray = json?["content"] as? [[String: Any]]
        #expect(contentArray != nil)
        #expect(contentArray?.count == 1)
        #expect(contentArray?.first?["text"] as? String == "System prompt")
        #expect(contentArray?.first?["type"] as? String == "text")
    }

    /// Декодирование строки → .text
    @Test("AIMessageContent декодируется из строки как .text")
    func messageContentDecodesFromString() throws {
        let json = """
        {"role": "user", "content": "Test message"}
        """
        let data = json.data(using: .utf8)!
        let message = try JSONDecoder().decode(AIMessage.self, from: data)

        if case .text(let text) = message.content {
            #expect(text == "Test message")
        } else {
            Issue.record("Ожидался .text, получен другой кейс")
        }
    }

    /// contentString работает для обоих кейсов.
    @Test("contentString возвращает текст для обоих кейсов AIMessageContent")
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

    /// AICacheControl кодируется с полем type = "ephemeral".
    @Test("AICacheControl кодируется правильно")
    func cacheControlEncodesCorrectly() throws {
        let cacheControl = AICacheControl()
        let data = try JSONEncoder().encode(cacheControl)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: String]

        #expect(json?["type"] == "ephemeral")
    }

    /// AIContentBlock.cached() создаёт блок с cache_control.
    @Test("AIContentBlock.cached() создаёт блок с cache_control")
    func contentBlockCachedHasCacheControl() throws {
        let block = AIContentBlock.cached("Cached text")
        #expect(block.cache_control != nil)
        #expect(block.cache_control?.type == "ephemeral")
        #expect(block.text == "Cached text")
        #expect(block.type == "text")
    }

    /// AIContentBlock.plain() создаёт блок без cache_control.
    @Test("AIContentBlock.plain() создаёт блок без cache_control")
    func contentBlockPlainHasNoCacheControl() {
        let block = AIContentBlock.plain("Plain text")
        #expect(block.cache_control == nil)
        #expect(block.text == "Plain text")
    }

    // MARK: - AITunnelRequest

    /// stream: false по умолчанию.
    @Test("AITunnelRequest.stream по умолчанию false")
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

    /// stream: true кодируется правильно.
    @Test("AITunnelRequest.stream = true кодируется правильно")
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

    // MARK: - AIStreamChunk

    /// Декодирование реального SSE-чанка.
    @Test("AIStreamChunk декодируется из реального SSE JSON")
    func streamChunkDecodesFromRealJSON() throws {
        let json = """
        {
            "id": "chatcmpl-abc123",
            "choices": [
                {
                    "delta": {"content": "Привет"},
                    "finish_reason": null
                }
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let chunk = try JSONDecoder().decode(AIStreamChunk.self, from: data)

        #expect(chunk.id == "chatcmpl-abc123")
        #expect(chunk.choices.count == 1)
        #expect(chunk.choices[0].delta.content == "Привет")
        #expect(chunk.choices[0].finish_reason == nil)
    }

    /// Декодирование финального чанка с usage.
    @Test("AIStreamChunk с usage декодируется правильно")
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

    /// AIUsage декодирует поля кэширования.
    @Test("AIUsage декодирует cache_creation и cache_read токены")
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

    // MARK: - Roundtrip тесты

    /// AIMessage проходит roundtrip encode → decode без потерь.
    @Test("AIMessage Codable roundtrip")
    func aiMessageRoundtrip() throws {
        let original = AIMessage(
            role: "user",
            content: "Тестовое сообщение",
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
