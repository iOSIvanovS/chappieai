// MigrationServiceTests.swift
// ChappieCoreTests
//
// Юнит-тесты для MigrationService (REFACTOR-THREADS IT-04).
//
// ЧТО ТЕСТИРУЕМ:
// 1. Идемпотентность — повторный вызов migrate() ничего не делает
// 2. Миграция без файлов — создаётся пустой тред
// 3. Миграция с chat_history.json — сообщения переносятся в тред
// 4. Миграция с semantic.json — записи памяти переносятся в MemoryStore
// 5. Сброс флага — resetMigrationFlag() позволяет повторить миграцию
//
// АРХИТЕКТУРНАЯ СЛОЖНОСТЬ:
// MigrationService работает с SwiftData (ThreadStore + MemoryStore).
// Для тестов создаём in-memory ModelContainer — он не пишет на диск,
// изолирован между тестами и работает быстро.
//
// GENERIC ТЕСТ-ТИП:
// Вместо реального ChatMessage (из UI-таргета) используем TestMessage — простой
// Codable struct. Это изолирует тест от UI-зависимостей.

import Testing
import Foundation
import SwiftData
@testable import ChappieCore

// MARK: - Вспомогательный тип сообщения для тестов

/// Минимальный Codable тип для тестирования Generic-методов MigrationService.
///
/// ПОЧЕМУ НЕ ChatMessage:
/// ChatMessage определён в Chappie (UI-таргет) и недоступен в ChappieCoreTests.
/// TestMessage воспроизводит только то что нужно для теста: Codable + Equatable.
private struct TestMessage: Codable, Equatable {
    let id: UUID
    let text: String

    init(text: String) {
        self.id = UUID()
        self.text = text
    }
}

// MARK: - MigrationServiceTests

@Suite("MigrationService Tests")
struct MigrationServiceTests {

    // MARK: - Вспомогательный метод создания in-memory контейнера

    /// Создаёт изолированный in-memory ModelContainer для тестов.
    ///
    /// ПОЧЕМУ IN-MEMORY:
    /// - Не пишет на диск — тесты не оставляют артефактов
    /// - Изолирован между запусками — нет проблем с остаточными данными
    /// - Быстрее файлового хранилища
    ///
    /// isStoredInMemoryOnly: true — ключевой параметр для тестовой изоляции.
    private func makeTestContainer() throws -> ModelContainer {
        let schema = Schema([
            ThreadEntity.self,
            ProjectEntity.self,
            MemoryEntity.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    /// Создаёт временный файл с JSON-содержимым для тестов.
    ///
    /// - Parameter content: Строка JSON для записи в файл
    /// - Returns: URL временного файла (в системной temp-директории)
    private func makeTempFile(content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Тест 1: Идемпотентность

    /// Повторный вызов migrate() возвращает false и не создаёт дубликаты.
    ///
    /// КРИТИЧЕСКИ ВАЖНО: Если миграция не идемпотентна — при каждом запуске
    /// приложения будет создаваться новый тред "Основной". Это катастрофа.
    @Test("Идемпотентность: повторный вызов migrate() возвращает false")
    func migrationIsIdempotent() async throws {
        let container = try makeTestContainer()
        let threadStore = ThreadStore(modelContainer: container)
        let memoryStore = MemoryStore(modelContainer: container)
        let service = MigrationService(threadStore: threadStore, memoryStore: memoryStore)

        // Сбрасываем флаг перед тестом (на случай если другой тест его поставил)
        await service.resetMigrationFlag()

        let emptyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent_\(UUID().uuidString).json")
        let semanticURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent_\(UUID().uuidString).json")

        // Первый вызов — должен вернуть true (миграция выполнена)
        let firstResult = await service.migrate(
            messageType: TestMessage.self,
            chatHistoryURL: emptyURL,
            semanticMemoryURL: semanticURL
        )
        #expect(firstResult == true)

        // Второй вызов — должен вернуть false (уже мигрировали)
        let secondResult = await service.migrate(
            messageType: TestMessage.self,
            chatHistoryURL: emptyURL,
            semanticMemoryURL: semanticURL
        )
        #expect(secondResult == false)

        // Проверяем флаг
        #expect(await service.isMigrationDone == true)

        // Сбрасываем флаг после теста чтобы не влиять на другие тесты
        await service.resetMigrationFlag()
    }

    // MARK: - Тест 2: Миграция без файлов

    /// Если файлы не существуют — создаётся пустой тред без ошибок.
    @Test("Без файлов: создаётся пустой тред 'Основной'")
    func migrationWithoutFiles() async throws {
        let container = try makeTestContainer()
        let threadStore = ThreadStore(modelContainer: container)
        let memoryStore = MemoryStore(modelContainer: container)
        let service = MigrationService(threadStore: threadStore, memoryStore: memoryStore)

        await service.resetMigrationFlag()

        let nonexistentChat = FileManager.default.temporaryDirectory
            .appendingPathComponent("no_chat_\(UUID().uuidString).json")
        let nonexistentSemantic = FileManager.default.temporaryDirectory
            .appendingPathComponent("no_semantic_\(UUID().uuidString).json")

        let result = await service.migrate(
            messageType: TestMessage.self,
            chatHistoryURL: nonexistentChat,
            semanticMemoryURL: nonexistentSemantic
        )

        #expect(result == true)

        // Должен быть создан один тред
        let threads = try await threadStore.loadThreads()
        #expect(threads.count == 1)
        #expect(threads.first?.title == "Основной")

        // Сообщений нет
        let messages = try await threadStore.loadMessages(
            fromThreadId: threads.first!.id,
            as: TestMessage.self
        )
        #expect(messages.isEmpty)

        await service.resetMigrationFlag()
    }

    // MARK: - Тест 3: Миграция с chat_history.json

    /// Сообщения из chat_history.json переносятся в тред "Основной".
    @Test("С chat_history.json: сообщения переносятся в тред")
    func migrationWithChatHistory() async throws {
        let container = try makeTestContainer()
        let threadStore = ThreadStore(modelContainer: container)
        let memoryStore = MemoryStore(modelContainer: container)
        let service = MigrationService(threadStore: threadStore, memoryStore: memoryStore)

        await service.resetMigrationFlag()

        // Создаём тестовые сообщения и записываем в файл
        let testMessages = [
            TestMessage(text: "Привет, Чаппи!"),
            TestMessage(text: "Как дела?"),
            TestMessage(text: "Отлично, работаем!")
        ]
        let chatHistoryURL = try makeTempFile(
            content: String(data: try JSONEncoder().encode(testMessages), encoding: .utf8)!
        )
        defer { try? FileManager.default.removeItem(at: chatHistoryURL) }

        let nonexistentSemantic = FileManager.default.temporaryDirectory
            .appendingPathComponent("no_semantic_\(UUID().uuidString).json")

        let result = await service.migrate(
            messageType: TestMessage.self,
            chatHistoryURL: chatHistoryURL,
            semanticMemoryURL: nonexistentSemantic
        )

        #expect(result == true)

        // Проверяем что тред создан с сообщениями
        let threads = try await threadStore.loadThreads()
        #expect(threads.count == 1)

        let migratedMessages = try await threadStore.loadMessages(
            fromThreadId: threads.first!.id,
            as: TestMessage.self
        )
        #expect(migratedMessages.count == 3)
        #expect(migratedMessages[0].text == "Привет, Чаппи!")
        #expect(migratedMessages[2].text == "Отлично, работаем!")

        await service.resetMigrationFlag()
    }

    // MARK: - Тест 4: Миграция с semantic.json

    /// Записи из semantic.json переносятся в MemoryStore с scope="global".
    @Test("С semantic.json: записи памяти переносятся в MemoryStore")
    func migrationWithSemanticMemory() async throws {
        let container = try makeTestContainer()
        let threadStore = ThreadStore(modelContainer: container)
        let memoryStore = MemoryStore(modelContainer: container)
        let service = MigrationService(threadStore: threadStore, memoryStore: memoryStore)

        await service.resetMigrationFlag()

        // Создаём legacy semantic.json формат
        // Формат: { "key": { "type": "...", "timestamp": "...", "data": "..." } }
        let semanticContent = """
        {
            "user_name": {
                "type": "fact",
                "timestamp": "2025-07-01T10:00:00Z",
                "data": "{\\"value\\": \\"Сергей\\"}"
            },
            "pipeline_rules": {
                "type": "rule",
                "timestamp": "2025-07-01T10:00:00Z",
                "data": "{\\"value\\": \\"Всегда делать checkpoint перед изменениями\\"}"
            }
        }
        """
        let semanticURL = try makeTempFile(content: semanticContent)
        defer { try? FileManager.default.removeItem(at: semanticURL) }

        let nonexistentChat = FileManager.default.temporaryDirectory
            .appendingPathComponent("no_chat_\(UUID().uuidString).json")

        let result = await service.migrate(
            messageType: TestMessage.self,
            chatHistoryURL: nonexistentChat,
            semanticMemoryURL: semanticURL
        )

        #expect(result == true)

        // Проверяем что записи памяти перенесены
        let entries = try await memoryStore.readAllEntries(scope: "global")
        #expect(entries.count == 2)

        // Проверяем что ключи на месте
        let keys = Set(entries.map { $0.key })
        #expect(keys.contains("user_name"))
        #expect(keys.contains("pipeline_rules"))

        // Проверяем типы
        let userNameEntry = entries.first { $0.key == "user_name" }
        #expect(userNameEntry?.type == "fact")

        await service.resetMigrationFlag()
    }

    // MARK: - Тест 5: Сброс флага

    /// resetMigrationFlag() позволяет повторно запустить миграцию.
    @Test("resetMigrationFlag: позволяет повторить миграцию")
    func resetFlagAllowsRemigration() async throws {
        let container = try makeTestContainer()
        let threadStore = ThreadStore(modelContainer: container)
        let memoryStore = MemoryStore(modelContainer: container)
        let service = MigrationService(threadStore: threadStore, memoryStore: memoryStore)

        await service.resetMigrationFlag()

        let emptyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty_\(UUID().uuidString).json")

        // Первая миграция
        _ = await service.migrate(
            messageType: TestMessage.self,
            chatHistoryURL: emptyURL,
            semanticMemoryURL: emptyURL
        )
        #expect(await service.isMigrationDone == true)

        // Сбрасываем флаг
        await service.resetMigrationFlag()
        #expect(await service.isMigrationDone == false)

        // Теперь миграция снова выполнится
        let result = await service.migrate(
            messageType: TestMessage.self,
            chatHistoryURL: emptyURL,
            semanticMemoryURL: emptyURL
        )
        #expect(result == true)

        // Убираем за собой
        await service.resetMigrationFlag()
    }
}
