// MemoryManagerTests.swift
// Тесты для MemoryManager — центрального компонента системы памяти Чаппи.
//
// СТРАТЕГИЯ ТЕСТИРОВАНИЯ:
// Каждый тест создаёт изолированную временную директорию через FileManager.
// Это гарантирует что тесты не влияют друг на друга и не засоряют реальный проект.
//
// ПОЧЕМУ ТЕСТИРУЕМ ИМЕННО ЭТО:
// MemoryManager — actor с файловой системой. Ошибки здесь приводят к потере
// контекста ИИ или его засорению. Тесты защищают от регрессий при рефакторинге.

import Testing
import Foundation
@testable import ChappieCore

@Suite("MemoryManager Tests")
struct MemoryManagerTests {

    // MARK: - Вспомогательные методы

    /// Создаёт временную директорию для изолированного теста.
    /// Каждый тест получает уникальную директорию — никакого пересечения данных.
    private func makeTempWorkspace() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChappieCoreTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    /// Удаляет временную директорию после теста.
    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Тесты сохранения и чтения

    /// Проверяем базовый сценарий: сохранили — прочитали.
    @Test("Сохранение и загрузка записи")
    func saveAndLoadRecord() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        let manager = MemoryManager(workspaceURL: workspace)
        await manager.initializeWorkspaceMemory()

        // Сохраняем в глобальную память — она не зависит от структуры таргетов
        // и потому наиболее предсказуема в тестах
        await manager.saveMemory(
            key: "test_key",
            type: "fact",
            jsonString: "{\"value\": \"hello\"}",
            scope: .global
        )

        let result = await manager.readMemory(key: "test_key")
        #expect(result == "{\"value\": \"hello\"}")
    }

    /// Проверяем что несуществующий ключ возвращает nil, а не крашит.
    @Test("Чтение несуществующего ключа возвращает nil")
    func readMissingKeyReturnsNil() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        let manager = MemoryManager(workspaceURL: workspace)
        await manager.initializeWorkspaceMemory()

        let result = await manager.readMemory(key: "nonexistent_key_12345")
        #expect(result == nil)
    }

    /// Проверяем перезапись: повторное сохранение по тому же ключу обновляет значение.
    @Test("Перезапись существующей записи")
    func overwriteExistingRecord() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        let manager = MemoryManager(workspaceURL: workspace)
        await manager.initializeWorkspaceMemory()

        await manager.saveMemory(key: "key", type: "fact", jsonString: "\"old\"", scope: .global)
        await manager.saveMemory(key: "key", type: "fact", jsonString: "\"new\"", scope: .global)

        let result = await manager.readMemory(key: "key")
        #expect(result == "\"new\"")
    }

    // MARK: - Тесты удаления

    /// Проверяем что удалённая запись больше не читается.
    @Test("Удаление записи")
    func deleteRecord() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        let manager = MemoryManager(workspaceURL: workspace)
        await manager.initializeWorkspaceMemory()

        await manager.saveMemory(key: "to_delete", type: "fact", jsonString: "\"data\"", scope: .global)

        let before = await manager.readMemory(key: "to_delete")
        #expect(before != nil)

        await manager.deleteMemory(key: "to_delete")

        let after = await manager.readMemory(key: "to_delete")
        #expect(after == nil)
    }

    // MARK: - Тесты поиска

    /// Проверяем поиск по типу: возвращает только записи нужного типа.
    @Test("Поиск по типу возвращает правильные записи")
    func searchByType() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        let manager = MemoryManager(workspaceURL: workspace)
        await manager.initializeWorkspaceMemory()

        // Сохраняем в глобальную память для предсказуемости
        await manager.saveMemory(key: "rule1", type: "rule", jsonString: "\"rule data\"", scope: .global)
        await manager.saveMemory(key: "fact1", type: "fact", jsonString: "\"fact data\"", scope: .global)
        await manager.saveMemory(key: "rule2", type: "rule", jsonString: "\"rule data 2\"", scope: .global)

        let rules = await manager.searchMemory(type: "rule")

        #expect(rules.count == 2)
        #expect(rules["rule1"] != nil)
        #expect(rules["rule2"] != nil)
        #expect(rules["fact1"] == nil)
    }

    /// Поиск по несуществующему типу возвращает пустой словарь.
    @Test("Поиск по несуществующему типу возвращает пустой словарь")
    func searchMissingTypeReturnsEmpty() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        let manager = MemoryManager(workspaceURL: workspace)
        await manager.initializeWorkspaceMemory()

        let results = await manager.searchMemory(type: "nonexistent_type_xyz")
        #expect(results.isEmpty)
    }

    // MARK: - Тесты множественных записей

    /// Проверяем что несколько записей хранятся независимо.
    @Test("Множественные записи хранятся независимо")
    func multipleRecordsStoredIndependently() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        let manager = MemoryManager(workspaceURL: workspace)
        await manager.initializeWorkspaceMemory()

        for i in 1...5 {
            await manager.saveMemory(
                key: "key_\(i)",
                type: "fact",
                jsonString: "\"value_\(i)\"",
                scope: .global
            )
        }

        for i in 1...5 {
            let result = await manager.readMemory(key: "key_\(i)")
            #expect(result == "\"value_\(i)\"")
        }
    }

    // MARK: - Тесты инициализации

    /// Проверяем что initializeWorkspaceMemory создаёт глобальный файл памяти.
    @Test("Инициализация создаёт глобальный файл памяти")
    func initializationCreatesGlobalFile() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        let manager = MemoryManager(workspaceURL: workspace)
        await manager.initializeWorkspaceMemory()

        let globalFile = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chappie/semantic.json")
        #expect(FileManager.default.fileExists(atPath: globalFile.path))
    }

    /// Проверяем идемпотентность: повторная инициализация не затирает данные.
    ///
    /// ПОЧЕМУ ИСПОЛЬЗУЕМ .global:
    /// Тест работает в изолированной временной директории без реальных таргетов
    /// (нет папок Chappie/ или ChappieCore/ внутри tempDir).
    /// MemoryManager не найдёт ни одного таргета и saveMemory(.project) упадёт
    /// в глобальную память как запасной вариант — но это недетерминировано.
    /// Поэтому явно используем .global, чтобы тест был стабильным в любой среде.
    @Test("Повторная инициализация не затирает данные (идемпотентность)")
    func initializationIsIdempotent() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        let manager = MemoryManager(workspaceURL: workspace)
        await manager.initializeWorkspaceMemory()

        // Сохраняем данные явно в глобальную память
        await manager.saveMemory(
            key: "persist_key",
            type: "fact",
            jsonString: "\"persist\"",
            scope: .global
        )

        // Сбрасываем флаг инициализации через повторное создание менеджера
        // (имитируем перезапуск приложения с тем же воркспейсом)
        let manager2 = MemoryManager(workspaceURL: workspace)
        await manager2.initializeWorkspaceMemory()

        // Данные должны сохраниться — глобальный файл не затирается при инициализации
        let result = await manager2.readMemory(key: "persist_key")
        #expect(result == "\"persist\"")
    }
}
