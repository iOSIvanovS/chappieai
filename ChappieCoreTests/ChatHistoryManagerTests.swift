// ChatHistoryManagerTests.swift
// ChappieCoreTests
//
// Юнит-тесты для ChatHistoryManager — менеджера персистентности истории чата.
//
// ВАЖНОСТЬ ЭТИХ ТЕСТОВ:
// История чата — это долгосрочная память пользователя. Если saveMessages/loadMessages
// сломаются при рефакторинге модели ChatMessage, пользователь потеряет всю историю.
// Тесты защищают от таких регрессий.
//
// ТЕСТОВАЯ МОДЕЛЬ:
// Используем SimpleMessage — минимальную Codable-структуру, независимую от
// реального ChatMessage из UI-слоя. Это правильно: ChatHistoryManager Generic,
// и тестировать его нужно с простой моделью, не тащя зависимости UI.
//
// ВАЖНЫЙ НЮАНС — изоляция от реальных данных:
// ChatHistoryManager(workspaceURL: tempDir) создаёт fileURL = tempDir/AI_Docs/chat_history.json
// Это ИЗОЛИРОВАННЫЙ путь, не связанный с реальной историей приложения.
// Тест loadEmptyHistory проверяет что при отсутствии файла возвращается [],
// а не содержимое реального chat_history.json из рабочего проекта.

import Testing
import Foundation
@testable import ChappieCore

// MARK: - Тестовая модель сообщения

/// Минимальная Codable-структура для тестирования ChatHistoryManager.
///
/// ПОЧЕМУ НЕ ИСПОЛЬЗУЕМ РЕАЛЬНЫЙ ChatMessage:
/// ChatMessage определён в UI-таргете Chappie, а не в ChappieCore.
/// Тесты ChappieCore не должны зависеть от UI-слоя — это нарушило бы
/// принцип разделения ответственности. SimpleMessage — правильная замена.
private struct SimpleMessage: Codable, Equatable {
    let id: String
    let text: String
    let isUser: Bool
}

@Suite("ChatHistoryManager Tests")
struct ChatHistoryManagerTests {

    // MARK: - Вспомогательные методы

    /// Создаёт ChatHistoryManager с уникальной временной директорией.
    ///
    /// КРИТИЧЕСКИ ВАЖНО: передаём workspaceURL явно, чтобы fileURL указывал
    /// на tempDir/AI_Docs/chat_history.json, а НЕ на глобальный файл истории.
    /// Без этого тест читал бы реальную историю чата приложения.
    private func makeManager() throws -> (ChatHistoryManager, URL) {
        // Создаём уникальную временную директорию для каждого теста
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CHMTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Явно передаём workspaceURL — это изолирует тест от реальных данных
        let manager = ChatHistoryManager(workspaceURL: tempDir)
        return (manager, tempDir)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Тесты базовых операций

    /// Пустая история при первом запуске — нормальная ситуация, не ошибка.
    ///
    /// Проверяем что при отсутствии файла chat_history.json возвращается [],
    /// а не данные из другого места (например, реальной истории приложения).
    @Test("Загрузка пустой истории при первом запуске")
    func loadEmptyHistoryOnFirstRun() throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        // Убеждаемся что файл истории ещё не существует в нашей изолированной директории
        // (миграция могла создать его — удаляем если есть)
        if FileManager.default.fileExists(atPath: manager.fileURL.path) {
            try FileManager.default.removeItem(at: manager.fileURL)
        }

        let messages: [SimpleMessage] = manager.loadMessages()
        // Файла нет — должен вернуться пустой массив
        #expect(messages.isEmpty)
    }

    /// Сохранили → загрузили → получили то же самое.
    @Test("Сохранение и загрузка истории")
    func saveAndLoadHistory() throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        let messages = [
            SimpleMessage(id: "1", text: "Привет, Чаппи!", isUser: true),
            SimpleMessage(id: "2", text: "Привет, Босс!", isUser: false)
        ]

        manager.saveMessages(messages)
        let loaded: [SimpleMessage] = manager.loadMessages()

        #expect(loaded == messages)
    }

    /// Очистка истории — файл удаляется, следующая загрузка возвращает пустой массив.
    @Test("Очистка истории")
    func clearHistory() throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        let messages = [SimpleMessage(id: "1", text: "test", isUser: true)]
        manager.saveMessages(messages)

        // Убеждаемся что файл существует
        #expect(FileManager.default.fileExists(atPath: manager.fileURL.path))

        manager.clearHistory()

        // После очистки файла не должно быть
        #expect(!FileManager.default.fileExists(atPath: manager.fileURL.path))

        // И загрузка должна вернуть пустой массив
        let loaded: [SimpleMessage] = manager.loadMessages()
        #expect(loaded.isEmpty)
    }

    /// Повторное сохранение перезаписывает предыдущую историю.
    @Test("Повторное сохранение перезаписывает историю")
    func resaveOverwritesPreviousHistory() throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        let first = [SimpleMessage(id: "1", text: "first", isUser: true)]
        let second = [SimpleMessage(id: "2", text: "second", isUser: false)]

        manager.saveMessages(first)
        manager.saveMessages(second)

        let loaded: [SimpleMessage] = manager.loadMessages()
        #expect(loaded == second)
        #expect(loaded.count == 1)
    }

    // MARK: - Тесты персистентности

    /// Данные сохраняются между созданием разных экземпляров менеджера (симуляция перезапуска).
    @Test("Персистентность между сессиями (симуляция перезапуска)")
    func persistenceBetweenSessions() throws {
        // Создаём общую директорию для обоих экземпляров менеджера
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CHMPersist_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let messages = [
            SimpleMessage(id: "1", text: "Запомни это", isUser: true),
            SimpleMessage(id: "2", text: "Запомнил!", isUser: false)
        ]

        // Первый экземпляр — сохраняем
        let manager1 = ChatHistoryManager(workspaceURL: tempDir)
        manager1.saveMessages(messages)

        // Второй экземпляр с тем же URL — симулируем перезапуск приложения
        let manager2 = ChatHistoryManager(workspaceURL: tempDir)
        let loaded: [SimpleMessage] = manager2.loadMessages()

        #expect(loaded == messages)
    }

    // MARK: - Тесты изоляции воркспейсов

    /// Два разных воркспейса хранят независимые истории.
    @Test("Изоляция историй между воркспейсами")
    func workspaceIsolation() throws {
        let tempDir1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("CHMIso1_\(UUID().uuidString)", isDirectory: true)
        let tempDir2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("CHMIso2_\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(at: tempDir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDir2, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir1)
            try? FileManager.default.removeItem(at: tempDir2)
        }

        let messages1 = [SimpleMessage(id: "1", text: "workspace 1", isUser: true)]
        let messages2 = [SimpleMessage(id: "2", text: "workspace 2", isUser: true)]

        let manager1 = ChatHistoryManager(workspaceURL: tempDir1)
        let manager2 = ChatHistoryManager(workspaceURL: tempDir2)

        manager1.saveMessages(messages1)
        manager2.saveMessages(messages2)

        // Каждый менеджер читает только свои данные
        let loaded1: [SimpleMessage] = manager1.loadMessages()
        let loaded2: [SimpleMessage] = manager2.loadMessages()

        #expect(loaded1 == messages1)
        #expect(loaded2 == messages2)
        // Данные не должны смешиваться
        #expect(loaded1 != loaded2)
    }

    // MARK: - Тесты фолбэка (без воркспейса)

    /// Менеджер без воркспейса работает с глобальным файлом — не крашит.
    @Test("Менеджер без воркспейса использует глобальный файл")
    func managerWithoutWorkspaceUsesGlobalFile() throws {
        // shared — это менеджер без воркспейса
        let manager = ChatHistoryManager.shared

        // Просто проверяем что fileURL указывает на что-то внутри Documents
        let documentsPath = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0].path
        #expect(manager.fileURL.path.hasPrefix(documentsPath))
    }
}
