// ChatHistoryManagerTests.swift
// Тесты для ChatHistoryManager — сохранение и загрузка истории чата.
// Каждый тест работает в изолированной временной директории,
// чтобы не зависеть от состояния файловой системы на диске.
//
// ИСТОРИЯ ИЗМЕНЕНИЙ:
// Тесты переписаны под актуальный API ChatHistoryManager после рефакторинга TD-02:
//   - init(workspaceURL:) вместо init(storageURL:)
//   - loadMessages<T>() вместо loadHistory()
//   - saveMessages<T>() вместо save(messages:)
//   - clearHistory() вместо clear()
//   - Тестовая модель TestMessage вместо несуществующего StoredMessage
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
    /// ПОЧЕМУ workspaceURL, А НЕ storageURL:
    /// После рефакторинга TD-02 менеджер принимает URL корневой папки воркспейса,
    /// а сам создаёт подпапку AI_Docs/ внутри неё. Это позволяет хранить историю
    /// прямо в проекте, рядом с кодом.
    private func makeManager() throws -> (ChatHistoryManager, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Передаём tempDir как workspaceURL — менеджер создаст AI_Docs/ внутри него
        let manager = ChatHistoryManager(workspaceURL: tempDir)
        return (manager, tempDir)
    }

    // MARK: - Тесты

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
    func clearHistory() throws {
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

    /// Файл истории создаётся внутри AI_Docs/ подпапки воркспейса.
    /// Это гарантирует что история хранится рядом с проектом, а не в случайном месте.
    @Test("История хранится в AI_Docs/ внутри воркспейса")
    func historyStoredInAIDocsSubdirectory() throws {
        let (manager, tempDir) = try makeManager()
        manager.saveMessages([TestMessage(role: "user", content: "Тест")])
        // Файл должен быть внутри AI_Docs/, а не в корне воркспейса
        let expectedDir = tempDir.appendingPathComponent("AI_Docs")
        #expect(manager.fileURL.deletingLastPathComponent() == expectedDir)
        #expect(FileManager.default.fileExists(atPath: manager.fileURL.path))
    }
}
