// MemoryManagerTests.swift
// ChappieCoreTests
//
// Юнит-тесты для MemoryManager — центрального компонента системы памяти Чаппи.
//
// СТРАТЕГИЯ ТЕСТИРОВАНИЯ:
// Каждый тест создаёт изолированную структуру воркспейса во временной директории.
// MemoryManager.discoverTargets() сканирует подпапки workspaceURL — поэтому создаём
// минимальную структуру с *App.swift для корректного обнаружения таргета.
//
// КЛЮЧЕВОЕ ИЗМЕНЕНИЕ АРХИТЕКТУРЫ (2026-06):
// semantic.json теперь ОДИН — ~/Documents/Chappie/semantic.json.
// Никаких semantic.json в таргетах воркспейса — только architecture.md.
// scope и targetName в API сохранены для совместимости, но игнорируются при выборе файла.
//
// ПРОБЛЕМА ИЗОЛЯЦИИ ТЕСТОВ:
// Все тесты теперь пишут в один глобальный ~/Documents/Chappie/semantic.json.
// Для изоляции используем UUID-суффиксы в ключах — это гарантирует уникальность
// и отсутствие конфликтов между тестами и реальными данными памяти.
//
// ПОЧЕМУ ТЕСТИРУЕМ ИМЕННО ЭТО:
// MemoryManager — actor с файловой системой. Ошибки здесь приводят к потере
// контекста ИИ или его засорению. Тесты защищают от регрессий при рефакторинге.

import Testing
import Foundation
@testable import ChappieCore

/// Тесты для MemoryManager.
/// Используем Swift Testing (не XCTest) — это современный подход для Swift 6.
@Suite("MemoryManager Tests")
struct MemoryManagerTests {

    // MARK: - Вспомогательные методы

    /// Создаёт структуру тестового воркспейса во временной директории.
    ///
    /// Структура:
    ///   tempDir/
    ///   └── TestApp/
    ///       └── TestApp.swift   ← суффикс App.swift → classifyTarget() вернёт .appTarget
    ///
    /// Воркспейс нужен для discoverTargets() — без него targets = [] и MemoryManager
    /// не сможет создать architecture.md (хотя это не влияет на работу памяти).
    private func makeTempWorkspace() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChappieCoreTests_\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

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

    /// Удаляет тестовые ключи из глобального semantic.json после теста.
    /// Это необходимо потому что все тесты пишут в один реальный глобальный файл.
    private func cleanupMemoryKeys(_ keys: [String], workspace: URL) async {
        let manager = MemoryManager(workspaceURL: workspace)
        for key in keys {
            await manager.deleteMemory(key: key)
        }
    }

    // MARK: - Тесты сохранения и чтения

    /// Проверяем базовый сценарий: сохранили — прочитали.
    /// Оба scope теперь пишут в один глобальный файл — поведение одинаковое.
    @Test("Сохранение и загрузка записи")
    func saveAndLoadRecord() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        let manager = MemoryManager(workspaceURL: workspace)
        await manager.initializeWorkspaceMemory()

        // UUID-ключ — защита от конфликтов с реальными данными памяти
        let uniqueKey = "test_key_\(UUID().uuidString)"
        defer { Task { await self.cleanupMemoryKeys([uniqueKey], workspace: workspace) } }

        await manager.saveMemory(
            key: uniqueKey,
            type: "fact",
            jsonString: "{\"value\": \"hello\"}"
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
        defer { Task { await self.cleanupMemoryKeys([uniqueKey], workspace: workspace) } }

        await manager.saveMemory(key: uniqueKey, type: "fact", jsonString: "\"old\"")
        await manager.saveMemory(key: uniqueKey, type: "fact", jsonString: "\"new\"")

        let result = await manager.readMemory(key: uniqueKey)
        #expect(result == "\"new\"")
    }

    // MARK: - Тесты scope (оба scope — один файл)

    /// Проверяем что scope: .project и scope: .global пишут в один файл.
    /// Запись через .project должна читаться через .global и наоборот.
    @Test("scope .project и .global используют один файл")
    func bothScopesUseSameFile() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        let manager = MemoryManager(workspaceURL: workspace)
        await manager.initializeWorkspaceMemory()

        let key1 = "scope_project_\(UUID().uuidString)"
        let key2 = "scope_global_\(UUID().uuidString)"
        defer { Task { await self.cleanupMemoryKeys([key1, key2], workspace: workspace) } }

        // Пишем через .project, читаем без указания scope
        await manager.saveMemory(key: key1, type: "fact", jsonString: "\"from project\"", scope: .project)
        let r1 = await manager.readMemory(key: key1)
        #expect(r1 == "\"from project\"", "Запись через scope .project должна читаться")

        // Пишем через .global, читаем без указания scope
        await manager.saveMemory(key: key2, type: "fact", jsonString: "\"from global\"", scope: .global)
        let r2 = await manager.readMemory(key: key2)
        #expect(r2 == "\"from global\"", "Запись через scope .global должна читаться")
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

        await manager.saveMemory(key: uniqueKey, type: "fact", jsonString: "\"data\"")

        let before = await manager.readMemory(key: uniqueKey)
        #expect(before != nil)

        await manager.deleteMemory(key: uniqueKey)

        let after = await manager.readMemory(key: uniqueKey)
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

        let suffix = UUID().uuidString
        let keys = ["rule1_\(suffix)", "fact1_\(suffix)", "rule2_\(suffix)"]
        defer { Task { await self.cleanupMemoryKeys(keys, workspace: workspace) } }

        await manager.saveMemory(key: "rule1_\(suffix)", type: "rule_\(suffix)", jsonString: "\"rule data\"")
        await manager.saveMemory(key: "fact1_\(suffix)", type: "fact_\(suffix)", jsonString: "\"fact data\"")
        await manager.saveMemory(key: "rule2_\(suffix)", type: "rule_\(suffix)", jsonString: "\"rule data 2\"")

        let rules = await manager.searchMemory(type: "rule_\(suffix)")

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
        let keys = (1...5).map { "key_\($0)_\(suffix)" }
        defer { Task { await self.cleanupMemoryKeys(keys, workspace: workspace) } }

        for i in 1...5 {
            await manager.saveMemory(
                key: "key_\(i)_\(suffix)",
                type: "fact",
                jsonString: "\"value_\(i)\""
            )
        }

        for i in 1...5 {
            let result = await manager.readMemory(key: "key_\(i)_\(suffix)")
            #expect(result == "\"value_\(i)\"")
        }
    }

    // MARK: - Тесты инициализации

    /// Проверяем что initializeWorkspaceMemory НЕ создаёт semantic.json в таргете.
    /// semantic.json должен быть ТОЛЬКО в ~/Documents/Chappie/ — не в воркспейсе.
    @Test("Инициализация НЕ создаёт semantic.json в таргете воркспейса")
    func initializationDoesNotCreateSemanticInTarget() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        let manager = MemoryManager(workspaceURL: workspace)
        await manager.initializeWorkspaceMemory()

        // semantic.json НЕ должен создаваться в таргете — только глобальный
        let semanticInTarget = workspace.appendingPathComponent("TestApp/semantic.json")
        #expect(!FileManager.default.fileExists(atPath: semanticInTarget.path),
                "semantic.json НЕ должен создаваться в таргете воркспейса")

        // AI_Docs/ тоже не должна создаваться
        let aiDocsDir = workspace.appendingPathComponent("TestApp/AI_Docs")
        #expect(!FileManager.default.fileExists(atPath: aiDocsDir.path),
                "Папка AI_Docs/ не должна создаваться")

        // architecture.md должен создаться (это единственный файл в таргете)
        let architectureFile = workspace.appendingPathComponent("TestApp/architecture.md")
        #expect(FileManager.default.fileExists(atPath: architectureFile.path),
                "architecture.md должен создаться в корне таргета")
    }

    /// Проверяем что устаревший semantic.json в корне таргета мигрируется и удаляется.
    ///
    /// Симулируем промежуточный формат: TestApp/semantic.json с данными.
    /// После initializeWorkspaceMemory() файл должен исчезнуть,
    /// а данные — мигрировать в ~/Documents/Chappie/semantic.json.
    @Test("Инициализация мигрирует и удаляет semantic.json из корня таргета")
    func initializationMigratesTargetSemanticJson() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        // Создаём устаревший semantic.json в корне таргета
        let targetSemanticURL = workspace.appendingPathComponent("TestApp/semantic.json")
        let legacyKey = "legacy_target_\(UUID().uuidString)"
        let legacyData: [String: Any] = [
            legacyKey: [
                "type": "fact",
                "timestamp": "2025-01-01T00:00:00Z",
                "data": "\"legacy target value\""
            ]
        ]
        let legacyJSON = try JSONSerialization.data(withJSONObject: legacyData)
        try legacyJSON.write(to: targetSemanticURL)

        // Запускаем инициализацию
        let manager = MemoryManager(workspaceURL: workspace)
        await manager.initializeWorkspaceMemory()
        defer { Task { await self.cleanupMemoryKeys([legacyKey], workspace: workspace) } }

        // semantic.json в таргете должен исчезнуть
        #expect(!FileManager.default.fileExists(atPath: targetSemanticURL.path),
                "semantic.json в таргете должен быть удалён после миграции")

        // Данные должны быть доступны через глобальную память
        let result = await manager.readMemory(key: legacyKey)
        #expect(result == "\"legacy target value\"",
                "Данные из таргетного semantic.json должны мигрировать в глобальный файл")
    }

    /// Проверяем что устаревшая папка AI_Docs/ удаляется при инициализации.
    @Test("Инициализация удаляет устаревшую AI_Docs и мигрирует данные")
    func initializationCleansUpLegacyAIDocs() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        // Создаём устаревшую структуру AI_Docs/ с данными
        let legacyAIDocsDir = workspace.appendingPathComponent("TestApp/AI_Docs")
        try FileManager.default.createDirectory(at: legacyAIDocsDir, withIntermediateDirectories: true)

        let legacySemanticURL = legacyAIDocsDir.appendingPathComponent("semantic.json")
        let legacyKey = "legacy_aidocs_\(UUID().uuidString)"
        let legacyData: [String: Any] = [
            legacyKey: [
                "type": "fact",
                "timestamp": "2025-01-01T00:00:00Z",
                "data": "\"legacy aidocs value\""
            ]
        ]
        let legacyJSON = try JSONSerialization.data(withJSONObject: legacyData)
        try legacyJSON.write(to: legacySemanticURL)

        let manager = MemoryManager(workspaceURL: workspace)
        await manager.initializeWorkspaceMemory()
        defer { Task { await self.cleanupMemoryKeys([legacyKey], workspace: workspace) } }

        // AI_Docs/ должна исчезнуть
        #expect(!FileManager.default.fileExists(atPath: legacyAIDocsDir.path),
                "Папка AI_Docs/ должна быть удалена после инициализации")

        // Данные должны быть доступны через глобальную память
        let result = await manager.readMemory(key: legacyKey)
        #expect(result == "\"legacy aidocs value\"",
                "Данные из AI_Docs/semantic.json должны мигрировать в глобальный файл")
    }

    /// Проверяем что повторная инициализация не влияет на существующие данные памяти.
    ///
    /// Данные записаны в ~/Documents/Chappie/semantic.json.
    /// Повторный вызов initializeWorkspaceMemory() не должен их затронуть.
    @Test("Повторная инициализация не затирает данные (идемпотентность)")
    func initializationIsIdempotent() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        let uniqueKey = "persist_\(UUID().uuidString)"

        // Первый экземпляр — сохраняем данные
        let manager1 = MemoryManager(workspaceURL: workspace)
        await manager1.initializeWorkspaceMemory()
        await manager1.saveMemory(key: uniqueKey, type: "fact", jsonString: "\"persist\"")
        defer { Task { await self.cleanupMemoryKeys([uniqueKey], workspace: workspace) } }

        let check = await manager1.readMemory(key: uniqueKey)
        #expect(check == "\"persist\"", "Данные должны быть доступны сразу после сохранения")

        // Второй экземпляр с тем же workspaceURL — симулируем перезапуск
        let manager2 = MemoryManager(workspaceURL: workspace)
        await manager2.initializeWorkspaceMemory()

        // Данные в глобальном файле должны сохраниться
        let result = await manager2.readMemory(key: uniqueKey)
        #expect(result == "\"persist\"", "Данные должны пережить повторную инициализацию")
    }
}
