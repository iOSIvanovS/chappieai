// MemoryManagerTests.swift
// ChappieCoreTests
//
// Юнит-тесты для MemoryManager — центрального компонента системы памяти Чаппи.
//
// СТРАТЕГИЯ ТЕСТИРОВАНИЯ:
// Каждый тест создаёт полноценную изолированную структуру воркспейса во временной директории.
// Это важно: MemoryManager.discoverTargets() сканирует подпапки workspaceURL в поисках таргетов.
// Если воркспейс пустой — targets = [] и saveMemory(scope: .project) падает в .global fallback.
// Поэтому мы создаём реалистичную структуру: подпапку таргета с *App.swift внутри.
//
// ПОЧЕМУ НЕ ИСПОЛЬЗУЕМ scope: .global В БОЛЬШИНСТВЕ ТЕСТОВ:
// scope: .global пишет в ~/Documents/Chappie/semantic.json — реальный файл системы.
// Это создаёт нежелательные побочные эффекты между тестами и засоряет реальную память.
// Вместо этого тестируем через scope: .project с изолированным воркспейсом.
//
// ФИНАЛЬНЫЙ ФОРМАТ ХРАНЕНИЯ (без AI_Docs/):
// - <target>/semantic.json    — данные памяти прямо в корне таргета
// - <target>/architecture.md  — документация архитектуры прямо в корне таргета
// Папка AI_Docs/ больше не создаётся — она удаляется при инициализации если осталась от старых версий.
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

        // Создаём корень воркспейса
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Создаём подпапку таргета с файлом *App.swift — это минимум для classifyTarget() → .appTarget
        let targetDir = tempDir.appendingPathComponent("TestApp", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        // Файл с суффиксом App.swift — сигнал для classifyTarget()
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
    /// Используем изолированный воркспейс — никакого влияния на реальную память.
    @Test("Сохранение и загрузка записи")
    func saveAndLoadRecord() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        let manager = MemoryManager(workspaceURL: workspace)
        await manager.initializeWorkspaceMemory()

        // Уникальный ключ с UUID — защита от конфликтов при параллельных тестах
        let uniqueKey = "test_key_\(UUID().uuidString)"

        // Сохраняем в scope .project — пишет в TestApp/semantic.json (изолировано!)
        await manager.saveMemory(
            key: uniqueKey,
            type: "fact",
            jsonString: "{\"value\": \"hello\"}",
            scope: .project
        )

        // readMemory без targetName → ищет в App-таргете (TestApp) → должен найти
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

        // Заведомо несуществующий ключ — UUID гарантирует уникальность
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
        // Должно вернуть новое значение, не старое
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

        // Убеждаемся что запись существует
        let before = await manager.readMemory(key: uniqueKey)
        #expect(before != nil)

        // Удаляем
        await manager.deleteMemory(key: uniqueKey)

        // Теперь должно быть nil
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

        // Уникальный суффикс чтобы не смешиваться с записями других тестов
        let suffix = UUID().uuidString

        // Сохраняем записи разных типов в scope .project
        await manager.saveMemory(key: "rule1_\(suffix)", type: "rule_\(suffix)", jsonString: "\"rule data\"", scope: .project)
        await manager.saveMemory(key: "fact1_\(suffix)", type: "fact_\(suffix)", jsonString: "\"fact data\"", scope: .project)
        await manager.saveMemory(key: "rule2_\(suffix)", type: "rule_\(suffix)", jsonString: "\"rule data 2\"", scope: .project)

        // Ищем только наш уникальный тип "rule"
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

        // Сохраняем 5 разных записей с уникальными ключами
        for i in 1...5 {
            await manager.saveMemory(
                key: "key_\(i)_\(suffix)",
                type: "fact",
                jsonString: "\"value_\(i)\"",
                scope: .project
            )
        }

        // Проверяем что каждая читается правильно
        for i in 1...5 {
            let result = await manager.readMemory(key: "key_\(i)_\(suffix)")
            #expect(result == "\"value_\(i)\"")
        }
    }

    // MARK: - Тесты инициализации

    /// Проверяем что initializeWorkspaceMemory создаёт semantic.json прямо в корне таргета.
    ///
    /// ФИНАЛЬНЫЙ ФОРМАТ: semantic.json лежит в <target>/semantic.json, НЕ в AI_Docs/.
    /// Папка AI_Docs/ не должна создаваться вообще.
    @Test("Инициализация создаёт semantic.json в корне таргета (без AI_Docs)")
    func initializationCreatesSemanticInTargetRoot() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        let manager = MemoryManager(workspaceURL: workspace)
        await manager.initializeWorkspaceMemory()

        // semantic.json должен лежать прямо в корне TestApp/, НЕ в AI_Docs/
        let semanticFile = workspace.appendingPathComponent("TestApp/semantic.json")
        #expect(FileManager.default.fileExists(atPath: semanticFile.path),
                "semantic.json должен существовать в корне таргета")

        // AI_Docs/ НЕ должна создаваться — это устаревший формат
        let aiDocsDir = workspace.appendingPathComponent("TestApp/AI_Docs")
        #expect(!FileManager.default.fileExists(atPath: aiDocsDir.path),
                "Папка AI_Docs/ не должна создаваться в новом формате")
    }

    /// Проверяем что устаревшая папка AI_Docs/ удаляется при инициализации.
    ///
    /// Симулируем старый формат: создаём TestApp/AI_Docs/semantic.json с данными.
    /// После initializeWorkspaceMemory() папка AI_Docs/ должна исчезнуть,
    /// а данные — мигрировать в TestApp/semantic.json.
    @Test("Инициализация удаляет устаревшую AI_Docs и мигрирует данные")
    func initializationCleansUpLegacyAIDocs() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        // Создаём устаревшую структуру AI_Docs/ с данными
        let legacyAIDocsDir = workspace.appendingPathComponent("TestApp/AI_Docs")
        try FileManager.default.createDirectory(at: legacyAIDocsDir, withIntermediateDirectories: true)

        // Кладём туда semantic.json с реальными данными для миграции
        let legacySemanticURL = legacyAIDocsDir.appendingPathComponent("semantic.json")
        let legacyKey = "legacy_key_\(UUID().uuidString)"
        let legacyData: [String: Any] = [
            legacyKey: [
                "type": "fact",
                "timestamp": "2025-01-01T00:00:00Z",
                "data": "\"legacy value\""
            ]
        ]
        let legacyJSON = try JSONSerialization.data(withJSONObject: legacyData)
        try legacyJSON.write(to: legacySemanticURL)

        // Запускаем инициализацию — она должна:
        // 1. Создать TestApp/semantic.json
        // 2. Мигрировать данные из AI_Docs/semantic.json
        // 3. Удалить папку AI_Docs/
        let manager = MemoryManager(workspaceURL: workspace)
        await manager.initializeWorkspaceMemory()

        // AI_Docs/ должна исчезнуть
        #expect(!FileManager.default.fileExists(atPath: legacyAIDocsDir.path),
                "Папка AI_Docs/ должна быть удалена после инициализации")

        // Данные должны быть доступны через новый путь
        let result = await manager.readMemory(key: legacyKey)
        #expect(result == "\"legacy value\"",
                "Данные из AI_Docs/semantic.json должны мигрировать в корневой semantic.json")
    }

    /// Проверяем что повторная инициализация не затирает существующие данные.
    ///
    /// СТРАТЕГИЯ ТЕСТА:
    /// Создаём manager1, инициализируем, сохраняем данные в scope .project (изолировано в TestApp/semantic.json).
    /// Затем создаём manager2 с тем же workspaceURL — симулирует перезапуск приложения.
    /// manager2.initializeWorkspaceMemory() не должен затереть TestApp/semantic.json.
    /// Читаем через manager2 — данные должны сохраниться.
    @Test("Повторная инициализация не затирает данные (идемпотентность)")
    func initializationIsIdempotent() async throws {
        let workspace = try makeTempWorkspace()
        defer { cleanup(workspace) }

        // Уникальный ключ чтобы не конфликтовать с другими тестами
        let uniqueKey = "persist_\(UUID().uuidString)"

        // Первый экземпляр — сохраняем данные в изолированный project scope
        let manager1 = MemoryManager(workspaceURL: workspace)
        await manager1.initializeWorkspaceMemory()
        await manager1.saveMemory(
            key: uniqueKey,
            type: "fact",
            jsonString: "\"persist\"",
            scope: .project
        )

        // Проверяем что данные сохранились через тот же экземпляр
        let check = await manager1.readMemory(key: uniqueKey)
        #expect(check == "\"persist\"", "Данные должны быть доступны сразу после сохранения")

        // Второй экземпляр с тем же workspaceURL — симулируем перезапуск
        // initializeWorkspaceMemory() не должен перезаписывать существующий semantic.json
        // (защита реализована через `if !fileManager.fileExists(atPath: target.semanticFileURL.path)`)
        let manager2 = MemoryManager(workspaceURL: workspace)
        await manager2.initializeWorkspaceMemory()

        // Данные должны сохраниться — файл не перезаписывается при инициализации
        let result = await manager2.readMemory(key: uniqueKey)
        #expect(result == "\"persist\"", "Данные должны пережить повторную инициализацию")
    }
}
