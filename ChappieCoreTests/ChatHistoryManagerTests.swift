// ChatHistoryManagerTests.swift
// Тесты для ChatHistoryManager — сохранение и загрузка истории чата.
// Каждый тест работает в изолированной временной директории,
// чтобы не зависеть от состояния файловой системы на диске.
//
// ИСТОРИЯ ИЗМЕНЕНИЙ:
// TD-02: Тесты переписаны под init(workspaceURL:), Generic loadMessages/saveMessages.
// TD-03: Обновлены под новое расположение файла (корень воркспейса, без AI_Docs/).
//        Добавлен тест на автоматическое подрезание до maxStoredMessages (100).
// 2026-05-25: Исправлено сравнение URL в historyStoredInWorkspaceRoot.
//             deletingLastPathComponent() добавляет trailing slash — нужен .standardized.
//
// ПОЧЕМУ TESTMESSAGE, А НЕ РЕАЛЬНЫЙ CHATMESSAGE:
// ChatHistoryManager живёт в ChappieCore и намеренно не зависит от ChatMessage,
// который определён в UI-слое Chappie.app. Менеджер Generic — он работает с любым Codable.
// Поэтому тесты используют простую тестовую модель, не создавая циклической зависимости.

import Testing
import Foundation
@testable import ChappieCore

// MARK: - Вспомогательная тестовая модель

/// Простая Codable-модель для тестирования Generic API менеджера.
/// Имитирует структуру сообщения без зависимости от UI-слоя.
private struct TestMessage: Codable, Equatable {
    let role: String
    let content: String
}

// MARK: - Тесты

@Suite("ChatHistoryManager Tests")
struct ChatHistoryManagerTests {

    // MARK: - Вспомогательный метод

    /// Создаём свежую временную директорию для каждого теста.
    /// Это гарантирует изоляцию — ни один тест не влияет на другой.
    ///
    /// После рефакторинга TD-03 менеджер кладёт файл прямо в корень воркспейса
    /// (без поддиректории AI_Docs/ — она упразднена).
    private func makeManager() throws -> (ChatHistoryManager, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let manager = ChatHistoryManager(workspaceURL: tempDir)
        return (manager, tempDir)
    }

    // MARK: - Базовые тесты

    /// При первом запуске файл истории не существует.
    /// Менеджер должен вернуть пустой массив, а не упасть.
    @Test("Загрузка пустой истории при первом запуске")
    func loadEmptyHistory() throws {
        let (manager, _) = try makeManager()
        let messages: [TestMessage] = manager.loadMessages()
        #expect(messages.isEmpty)
    }

    /// Сохраняем одно сообщение и проверяем что оно читается обратно.
    @Test("Сохранение и загрузка одного сообщения")
    func saveAndLoadSingleMessage() throws {
        let (manager, _) = try makeManager()
        let message = TestMessage(role: "user", content: "Привет, Чаппи!")
        manager.saveMessages([message])
        let loaded: [TestMessage] = manager.loadMessages()
        #expect(loaded.count == 1)
        #expect(loaded.first?.content == "Привет, Чаппи!")
    }

    /// Сохраняем несколько сообщений — порядок должен сохраниться.
    @Test("Порядок сообщений сохраняется")
    func messageOrderPreserved() throws {
        let (manager, _) = try makeManager()
        let messages = [
            TestMessage(role: "user", content: "Первое"),
            TestMessage(role: "assistant", content: "Второе"),
            TestMessage(role: "user", content: "Третье")
        ]
        manager.saveMessages(messages)
        let loaded: [TestMessage] = manager.loadMessages()
        #expect(loaded.count == 3)
        #expect(loaded[0].content == "Первое")
        #expect(loaded[1].content == "Второе")
        #expect(loaded[2].content == "Третье")
    }

    /// Повторное сохранение должно перезаписывать старые данные, а не дублировать.
    @Test("Повторное сохранение перезаписывает историю")
    func overwriteHistory() throws {
        let (manager, _) = try makeManager()
        manager.saveMessages([TestMessage(role: "user", content: "Старое")])
        manager.saveMessages([TestMessage(role: "user", content: "Новое")])
        let loaded: [TestMessage] = manager.loadMessages()
        #expect(loaded.count == 1)
        #expect(loaded.first?.content == "Новое")
    }

    /// Очистка истории должна приводить к пустому массиву при следующей загрузке.
    @Test("Очистка истории")
    func clearHistoryTest() throws {
        let (manager, _) = try makeManager()
        manager.saveMessages([TestMessage(role: "user", content: "Что-то")])
        manager.clearHistory()
        let loaded: [TestMessage] = manager.loadMessages()
        #expect(loaded.isEmpty)
    }

    /// Роли сообщений должны сохраняться без искажений.
    @Test("Роли сообщений сохраняются корректно")
    func rolesPreserved() throws {
        let (manager, _) = try makeManager()
        let messages = [
            TestMessage(role: "user", content: "Вопрос"),
            TestMessage(role: "assistant", content: "Ответ")
        ]
        manager.saveMessages(messages)
        let loaded: [TestMessage] = manager.loadMessages()
        #expect(loaded[0].role == "user")
        #expect(loaded[1].role == "assistant")
    }

    // MARK: - Тест расположения файла (TD-03)

    /// После рефакторинга TD-03 файл истории лежит прямо в корне воркспейса.
    /// Папка AI_Docs/ упразднена — проверяем новое расположение.
    ///
    /// ВАЖНО: используем .standardized для сравнения URL, потому что
    /// deletingLastPathComponent() добавляет trailing slash ("/UUID/"),
    /// а tempDir создаётся без него ("/UUID"). URL-сравнение строгое —
    /// .standardized нормализует оба URL к единому виду без trailing slash.
    @Test("История хранится в корне воркспейса (без AI_Docs/)")
    func historyStoredInWorkspaceRoot() throws {
        let (manager, tempDir) = try makeManager()
        manager.saveMessages([TestMessage(role: "user", content: "Тест")])

        // Нормализуем оба URL через .standardized чтобы убрать разницу в trailing slash
        let parentDir = manager.fileURL.deletingLastPathComponent().standardized
        let expectedDir = tempDir.standardized

        #expect(parentDir == expectedDir,
                "Файл должен лежать прямо в корне воркспейса, не в поддиректории")
        #expect(manager.fileURL.lastPathComponent == "chat_history.json")
        #expect(FileManager.default.fileExists(atPath: manager.fileURL.path))
    }

    // MARK: - Тест автоматического подрезания (TD-03)

    /// При сохранении более maxStoredMessages сообщений старые должны отбрасываться.
    /// Сохраняются только последние N — самые свежие и актуальные.
    @Test("Автоматическое подрезание до maxStoredMessages")
    func autoTrimToMaxStoredMessages() throws {
        let (manager, _) = try makeManager()
        let limit = ChatHistoryManager.maxStoredMessages

        // Создаём limit + 10 сообщений — намеренно превышаем лимит
        let messages = (0..<(limit + 10)).map { i in
            TestMessage(role: "user", content: "Сообщение \(i)")
        }
        manager.saveMessages(messages)

        let loaded: [TestMessage] = manager.loadMessages()

        // После сохранения должно остаться ровно limit сообщений
        #expect(loaded.count == limit)

        // Должны сохраниться ПОСЛЕДНИЕ сообщения (самые свежие)
        // Первые 10 должны быть отброшены
        #expect(loaded.first?.content == "Сообщение 10")
        #expect(loaded.last?.content == "Сообщение \(limit + 9)")
    }

    /// Если сообщений меньше лимита — подрезание не происходит, все сохраняются.
    @Test("Без подрезания если сообщений меньше лимита")
    func noTrimWhenUnderLimit() throws {
        let (manager, _) = try makeManager()
        let count = ChatHistoryManager.maxStoredMessages - 10
        let messages = (0..<count).map { i in
            TestMessage(role: "user", content: "Сообщение \(i)")
        }
        manager.saveMessages(messages)
        let loaded: [TestMessage] = manager.loadMessages()
        // Все сообщения должны сохраниться без изменений
        #expect(loaded.count == count)
    }

    /// Ровно на границе лимита — подрезания нет, все сохраняются.
    @Test("Ровно на границе лимита — подрезания нет")
    func exactlyAtLimitNoBoundaryTrim() throws {
        let (manager, _) = try makeManager()
        let limit = ChatHistoryManager.maxStoredMessages
        let messages = (0..<limit).map { i in
            TestMessage(role: "user", content: "Сообщение \(i)")
        }
        manager.saveMessages(messages)
        let loaded: [TestMessage] = manager.loadMessages()
        #expect(loaded.count == limit)
    }
}
