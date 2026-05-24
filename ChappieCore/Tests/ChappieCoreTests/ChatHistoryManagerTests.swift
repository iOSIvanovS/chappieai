// ChatHistoryManagerTests.swift
// Тесты для ChatHistoryManager — сохранение и загрузка истории чата.
// Каждый тест работает в изолированной временной директории,
// чтобы не зависеть от состояния файловой системы на диске.

import Testing
import Foundation
@testable import ChappieCore

@Suite("ChatHistoryManager Tests")
struct ChatHistoryManagerTests {

    // MARK: - Вспомогательный метод

    /// Создаём свежую временную директорию для каждого теста.
    /// Это гарантирует изоляцию — ни один тест не влияет на другой.
    private func makeManager() throws -> (ChatHistoryManager, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let manager = ChatHistoryManager(storageURL: tempDir)
        return (manager, tempDir)
    }

    // MARK: - Тесты

    /// При первом запуске файл истории не существует.
    /// Менеджер должен вернуть пустой массив, а не упасть.
    @Test("Загрузка пустой истории при первом запуске")
    func loadEmptyHistory() async throws {
        let (manager, _) = try makeManager()
        // Явно ждём завершения асинхронной загрузки
        let messages = await manager.loadHistory()
        #expect(messages.isEmpty)
    }

    /// Сохраняем одно сообщение и проверяем что оно читается обратно.
    @Test("Сохранение и загрузка одного сообщения")
    func saveAndLoadSingleMessage() async throws {
        let (manager, _) = try makeManager()
        let message = StoredMessage(role: "user", content: "Привет, Чаппи!")
        await manager.save(messages: [message])
        let loaded = await manager.loadHistory()
        #expect(loaded.count == 1)
        #expect(loaded.first?.content == "Привет, Чаппи!")
    }

    /// Сохраняем несколько сообщений — порядок должен сохраниться.
    @Test("Порядок сообщений сохраняется")
    func messageOrderPreserved() async throws {
        let (manager, _) = try makeManager()
        let messages = [
            StoredMessage(role: "user", content: "Первое"),
            StoredMessage(role: "assistant", content: "Второе"),
            StoredMessage(role: "user", content: "Третье")
        ]
        await manager.save(messages: messages)
        let loaded = await manager.loadHistory()
        #expect(loaded.count == 3)
        #expect(loaded[0].content == "Первое")
        #expect(loaded[1].content == "Второе")
        #expect(loaded[2].content == "Третье")
    }

    /// Повторное сохранение должно перезаписывать старые данные, а не дублировать.
    @Test("Повторное сохранение перезаписывает историю")
    func overwriteHistory() async throws {
        let (manager, _) = try makeManager()
        await manager.save(messages: [StoredMessage(role: "user", content: "Старое")])
        await manager.save(messages: [StoredMessage(role: "user", content: "Новое")])
        let loaded = await manager.loadHistory()
        #expect(loaded.count == 1)
        #expect(loaded.first?.content == "Новое")
    }

    /// Очистка истории должна приводить к пустому массиву при следующей загрузке.
    @Test("Очистка истории")
    func clearHistory() async throws {
        let (manager, _) = try makeManager()
        await manager.save(messages: [StoredMessage(role: "user", content: "Что-то")])
        await manager.clear()
        let loaded = await manager.loadHistory()
        #expect(loaded.isEmpty)
    }

    /// Роли сообщений должны сохраняться без искажений.
    @Test("Роли сообщений сохраняются корректно")
    func rolesPreserved() async throws {
        let (manager, _) = try makeManager()
        let messages = [
            StoredMessage(role: "user", content: "Вопрос"),
            StoredMessage(role: "assistant", content: "Ответ")
        ]
        await manager.save(messages: messages)
        let loaded = await manager.loadHistory()
        #expect(loaded[0].role == "user")
        #expect(loaded[1].role == "assistant")
    }
}
