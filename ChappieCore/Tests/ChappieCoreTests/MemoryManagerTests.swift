// MemoryManagerTests.swift
// ChappieCore/Tests/ChappieCoreTests
//
// ВАЖНО: Этот файл синхронизирован с ChappieCoreTests/MemoryManagerTests.swift
// в корне проекта. Package.swift запускает тесты именно отсюда (path: "Tests/ChappieCoreTests").
// Тестплан Xcode (ChappieCoreTests.xctestplan) запускает тесты из корневого ChappieCoreTests/.
// Оба набора должны быть идентичны.
//
// СТРАТЕГИЯ ТЕСТИРОВАНИЯ:
// Каждый тест создаёт полноценную изолированную структуру воркспейса во временной директории.
// Это важно: MemoryManager.discoverTargets() сканирует подпапки workspaceURL в поисках таргетов.
// Если воркспейс пустой — targets = [] и saveMemory(scope: .project) падает в .global fallback.
// Поэтому мы создаём реалистичную структуру: подпапку таргета с *App.swift внутри.
//
// ПОЧЕМУ НЕ ИСПОЛЬЗУЕМ scope: .global В БОЛЬШИНСТВЕ ТЕСТОВ:
// scope: .global пишет в ~/Documents/Chappie/semantic.json — реальный файл системы.
// Это создаёт нежелательные побочные эффекты: реальная память Чаппи засоряется,
// а тесты "Поиск по типу" могут найти записи из реальной работы ИИ.
// Вместо этого тестируем через scope: .project с изолированным воркспейсом.

import Testing
import Foundation
@testable import ChappieCore

@Suite("MemoryManager Tests")
struct MemoryManagerTests {

    // MARK: - Вспомогательные методы

    /// Создаёт полноценную структуру тестового воркспейса во временной директории.
    ///
    /// ПОЧЕМУ НУЖНА ПОЛНОЦЕННАЯ СТРУКТУРА:
    /// MemoryManager.discoverTargets() сканирует подпапки workspaceURL.
    /// Пустая директория даёт targets = [] и поломанное поведение saveMemory/readMemory.
    /// Создаём минимально необходимую структуру: подпапку с *App.swift → classifyTarget() → .appTarget.
    ///
    /// Структура:
    ///   tempDir/
    ///   └── TestApp/
    ///       └── TestApp.swift   ← содержит "App.swift" суффикс → classifyTarget() вернёт .appTarget
    private func makeTempWorkspace() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChappieCoreTests_\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Создаём подпапку таргета с файлом *App.swift — сигнал для classifyTarget()
        let targetDir = tempDir.appendingPathComponent("TestApp", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let appFile = targetDir.appendingPathComponent("TestApp.swift")
        try "@main struct TestApp: App { var body: some Scene { WindowGroup { } } }"
            .write(to: appFile, atomically: true, encoding: .utf8)

        return tempDir
    }

    /// Удаляет временную директорию после теста.
    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Тесты сохранения и чтения

    /// Проверяем базовый сценарий: сохранили — прочитали через scope: .project.
    @Test("Сохранение и загрузка записи")
    func saveAndLoadRecord() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        let manager = MemoryManager(workspaceURL: workspace)
        await manager.initializeWorkspaceMemory()

        // Уникальный ключ с UUID — защита от конфликтов при параллельных тестах
        let uniqueKey = "test_key_\(UUID().uuidString)"

        // scope: .project — пишет в TestApp/AI_Docs/semantic.json (изолировано!)
        await manager.saveMemory(
            key: uniqueKey,
            type: "fact",
            jsonString: "{\"value\": \"hello\"}",
            scope: .project
        )

        let result = await manager.readMemory(key: uniqueKey)
        #expect(result == "{\"value\": \"hello\"}")
    }

    /// Проверяем что несуществующий ключ возвращает nil, а не крашит.
    @Test("Чтение несуществующего ключа возвращает nil")
    func readMissingKeyReturnsNil() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        let manager = MemoryManager(workspaceURL: workspace)
        await manager.initializeWorkspaceMemory()

        // UUID гарантирует что такого ключа точно нет
        let result = await manager.readMemory(key: "nonexistent_\(UUID().uuidString)")
        #expect(result == nil)
    }

    /// Проверяем перезапись: повторное сохранение по тому же ключу обновляет значение.
    @Test("Перезапись существующей записи")
    func overwriteExistingRecord() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        let manager = MemoryManager(workspaceURL: workspace)
        await manager.initializeWorkspaceMemory()

        let uniqueKey = "overwrite_\(UUID().uuidString)"

        await manager.saveMemory(key: uniqueKey, type: "fact", jsonString: "\"old\"", scope: .project)
        await manager.saveMemory(key: uniqueKey, type: "fact", jsonString: "\"new\"", scope: .project)

        let result = await manager.readMemory(key: uniqueKey)
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

        let uniqueKey = "delete_\(UUID().uuidString)"

        await manager.saveMemory(key: uniqueKey, type: "fact", jsonString: "\"data\"", scope: .project)

        let before = await manager.readMemory(key: uniqueKey)
        #expect(before != nil)

        await manager.deleteMemory(key: uniqueKey)

        let after = await manager.readMemory(key: uniqueKey)
        #expect(after == nil)
    }

    // MARK: - Тесты поиска

    /// Проверяем поиск по типу: возвращает только записи нужного типа.
    ///
    /// ПОЧЕМУ УНИКАЛЬНЫЙ СУФФИКС ДЛЯ ТИПА:
    /// searchMemory ищет по всем известным таргетам. Если использовать тип "rule" —
    /// реальная память Чаппи (~/Documents/Chappie/semantic.json) может уже содержать
    /// записи этого типа. UUID в имени типа гарантирует что мы найдём только свои записи.
    @Test("Поиск по типу возвращает правильные записи")
    func searchByType() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        let manager = MemoryManager(workspaceURL: workspace)
        await manager.initializeWorkspaceMemory()

        // Уникальный суффикс для типа — защита от реальных данных в глобальной памяти
        let suffix = UUID().uuidString

        await manager.saveMemory(key: "rule1_\(suffix)", type: "rule_\(suffix)", jsonString: "\"rule data\"", scope: .project)
        await manager.saveMemory(key: "fact1_\(suffix)", type: "fact_\(suffix)", jsonString: "\"fact data\"", scope: .project)
        await manager.saveMemory(key: "rule2_\(suffix)", type: "rule_\(suffix)", jsonString: "\"rule data 2\"", scope: .project)

        let rules = await manager.searchMemory(type: "rule_\(suffix)")

        // Должно быть ровно 2 записи нашего уникального типа
        #expect(rules.count == 2)
        #expect(rules["rule1_\(suffix)"] != nil)
        #expect(rules["rule2_\(suffix)"] != nil)
        #expect(rules["fact1_\(suffix)"] == nil)
    }

    /// Поиск по несуществующему типу возвращает пустой словарь, не крашит.
    @Test("Поиск по несуществующему типу возвращает пустой словарь")
    func searchMissingTypeReturnsEmpty() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        let manager = MemoryManager(workspaceURL: workspace)
        await manager.initializeWorkspaceMemory()

        // UUID гарантирует что такого типа точно не существует
        let results = await manager.searchMemory(type: "nonexistent_\(UUID().uuidString)")
        #expect(results.isEmpty)
    }

    // MARK: - Тесты множественных записей

    /// Проверяем что несколько записей хранятся независимо и не перезаписывают друг друга.
    @Test("Множественные записи хранятся независимо")
    func multipleRecordsStoredIndependently() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        let manager = MemoryManager(workspaceURL: workspace)
        await manager.initializeWorkspaceMemory()

        let suffix = UUID().uuidString

        for i in 1...5 {
            await manager.saveMemory(
                key: "key_\(i)_\(suffix)",
                type: "fact",
                jsonString: "\"value_\(i)\"",
                scope: .project
            )
        }

        for i in 1...5 {
            let result = await manager.readMemory(key: "key_\(i)_\(suffix)")
            #expect(result == "\"value_\(i)\"")
        }
    }

    // MARK: - Тесты инициализации

    /// Проверяем что initializeWorkspaceMemory создаёт нужные директории.
    @Test("Инициализация создаёт директорию AI_Docs")
    func initializationCreatesAIDocs() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        let manager = MemoryManager(workspaceURL: workspace)
        await manager.initializeWorkspaceMemory()

        // AI_Docs внутри TestApp-таргета должен существовать после инициализации
        let aiDocsDir = workspace.appendingPathComponent("TestApp/AI_Docs", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: aiDocsDir.path))

        // semantic.json внутри AI_Docs должен существовать
        let semanticFile = workspace.appendingPathComponent("TestApp/AI_Docs/semantic.json")
        #expect(FileManager.default.fileExists(atPath: semanticFile.path))
    }

    /// Проверяем что повторная инициализация не затирает существующие данные.
    ///
    /// СТРАТЕГИЯ: создаём manager1, сохраняем данные, создаём manager2 с тем же воркспейсом
    /// (имитирует перезапуск приложения) — данные должны пережить повторную инициализацию.
    @Test("Повторная инициализация не затирает данные (идемпотентность)")
    func initializationIsIdempotent() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        let uniqueKey = "persist_\(UUID().uuidString)"

        let manager1 = MemoryManager(workspaceURL: workspace)
        await manager1.initializeWorkspaceMemory()
        await manager1.saveMemory(
            key: uniqueKey,
            type: "fact",
            jsonString: "\"persist\"",
            scope: .project
        )

        let check = await manager1.readMemory(key: uniqueKey)
        #expect(check == "\"persist\"", "Данные должны быть доступны сразу после сохранения")

        // Второй экземпляр — симулируем перезапуск
        let manager2 = MemoryManager(workspaceURL: workspace)
        await manager2.initializeWorkspaceMemory()

        let result = await manager2.readMemory(key: uniqueKey)
        #expect(result == "\"persist\"", "Данные должны пережить повторную инициализацию")
    }
}
