// MemoryStore.swift
// ChappieCore
//
// НАЗНАЧЕНИЕ:
// Актор для CRUD-операций над трёхуровневой памятью через SwiftData (REFACTOR-THREADS IT-03).
//
// ТРЁХУРОВНЕВАЯ ПАМЯТЬ:
// 1. Глобальная (scope = "global") — факты о пользователе, стиль общения, кросс-проектные знания
// 2. Проектная (scope = "<projectId>") — архитектура проекта, пайплайны, договорённости
// 3. Тредовая (scope = "<threadId>") — контекст текущей задачи, временные заметки
//
// АРХИТЕКТУРА:
// MemoryStore — тонкий слой персистентности. Он не знает о содержимом памяти,
// только о том как её хранить и читать. Логика форматирования памяти для system prompt
// живёт в MemoryManager.buildSystemPrompt() — единственном месте сборки промпта.
//
// ПОЧЕМУ ACTOR:
// ModelContext не является Sendable. Actor гарантирует последовательный доступ
// к контексту SwiftData без гонок данных — стандартный паттерн для Swift 6.
//
// СОВМЕСТИМОСТЬ С LEGACY MemoryManager:
// MemoryStore работает ПАРАЛЛЕЛЬНО с существующим MemoryManager (файловым).
// Миграция semantic.json → SwiftData происходит в IT-04 (MigrationService).
// До завершения миграции MemoryManager продолжает работать как раньше.

import Foundation
import SwiftData

// MARK: - MemoryStore

/// Актор для управления записями памяти в SwiftData.
///
/// Все методы изолированы в акторе — безопасный конкурентный доступ гарантирован.
/// UI-слой и MemoryManager вызывают методы через await.
public actor MemoryStore {

    // MARK: - Свойства

    /// Контейнер SwiftData — Sendable, безопасно хранить в actor.
    /// Контекст создаётся при каждой операции через makeContext().
    private let modelContainer: ModelContainer

    // MARK: - Инициализация

    /// Создаёт MemoryStore с указанным ModelContainer.
    ///
    /// - Parameter modelContainer: Контейнер SwiftData (создаётся в ChappieApp.swift)
    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Вспомогательный метод создания контекста

    /// Создаёт новый ModelContext для операций внутри actor.
    ///
    /// ПОЧЕМУ СОЗДАЁМ КАЖДЫЙ РАЗ:
    /// ModelContext не является Sendable — нельзя хранить его как свойство actor.
    /// Создание нового контекста — стандартная практика для background SwiftData операций.
    private func makeContext() -> ModelContext {
        ModelContext(modelContainer)
    }

    // MARK: - Запись памяти

    /// Сохраняет или обновляет запись памяти по ключу в указанном scope.
    ///
    /// ЛОГИКА UPSERT:
    /// Если контейнер для scope уже существует — обновляем запись в нём.
    /// Если нет — создаём новый контейнер и добавляем запись.
    /// Если запись с таким ключом уже есть — перезаписываем.
    ///
    /// - Parameters:
    ///   - key: Уникальный ключ записи в рамках scope
    ///   - type: Тип записи (fact, rule, persona, project_map, pipeline и т.д.)
    ///   - jsonString: Содержимое записи в формате JSON-строки
    ///   - scope: Область памяти ("global", UUID проекта или UUID треда)
    /// - Throws: Ошибка SwiftData если сохранение не удалось
    public func saveEntry(
        key: String,
        type: String,
        jsonString: String,
        scope: String
    ) throws {
        let context = makeContext()
        let entity = try findOrCreateEntity(scope: scope, in: context)

        var entries = entity.entries

        // UPSERT: ищем существующую запись по ключу
        if let index = entries.firstIndex(where: { $0.key == key }) {
            // Обновляем существующую запись
            entries[index].jsonString = jsonString
            entries[index].type = type
            entries[index].updatedAt = Date()
        } else {
            // Добавляем новую запись
            let newEntry = MemoryEntry(key: key, type: type, jsonString: jsonString)
            entries.append(newEntry)
        }

        entity.setEntries(entries)
        try context.save()

        print("[MemoryStore] ✅ Сохранена запись '\(key)' в scope='\(scope)'")
    }

    // MARK: - Чтение памяти

    /// Читает одну запись памяти по ключу из указанного scope.
    ///
    /// - Parameters:
    ///   - key: Ключ записи
    ///   - scope: Область памяти
    /// - Returns: JSON-строка содержимого или nil если запись не найдена
    /// - Throws: Ошибка SwiftData если запрос не удался
    public func readEntry(key: String, scope: String) throws -> String? {
        let context = makeContext()
        guard let entity = try findEntity(scope: scope, in: context) else {
            return nil
        }
        return entity.entries.first(where: { $0.key == key })?.jsonString
    }

    /// Читает все записи из указанного scope.
    ///
    /// Используется в buildSystemPrompt() для подмешивания памяти в промпт.
    ///
    /// - Parameter scope: Область памяти
    /// - Returns: Массив записей (пустой если scope не существует)
    /// - Throws: Ошибка SwiftData если запрос не удался
    public func readAllEntries(scope: String) throws -> [MemoryEntry] {
        let context = makeContext()
        guard let entity = try findEntity(scope: scope, in: context) else {
            return []
        }
        return entity.entries
    }

    /// Ищет все записи указанного типа в scope.
    ///
    /// - Parameters:
    ///   - type: Тип записи для фильтрации
    ///   - scope: Область памяти
    /// - Returns: Словарь [ключ: JSON-строка] для записей с указанным типом
    /// - Throws: Ошибка SwiftData если запрос не удался
    public func searchEntries(type: String, scope: String) throws -> [String: String] {
        let context = makeContext()
        guard let entity = try findEntity(scope: scope, in: context) else {
            return [:]
        }
        var results: [String: String] = [:]
        for entry in entity.entries where entry.type == type {
            results[entry.key] = entry.jsonString
        }
        return results
    }

    // MARK: - Удаление памяти

    /// Удаляет запись по ключу из указанного scope.
    ///
    /// - Parameters:
    ///   - key: Ключ записи для удаления
    ///   - scope: Область памяти
    /// - Throws: Ошибка SwiftData если сохранение не удалось
    public func deleteEntry(key: String, scope: String) throws {
        let context = makeContext()
        guard let entity = try findEntity(scope: scope, in: context) else { return }

        var entries = entity.entries
        let countBefore = entries.count
        entries.removeAll { $0.key == key }

        guard entries.count < countBefore else {
            print("[MemoryStore] ℹ️ Запись '\(key)' не найдена в scope='\(scope)'")
            return
        }

        entity.setEntries(entries)
        try context.save()

        print("[MemoryStore] 🗑 Удалена запись '\(key)' из scope='\(scope)'")
    }

    /// Удаляет весь scope целиком (например, при удалении треда или проекта).
    ///
    /// ВНИМАНИЕ: Удаляет ВСЕ записи памяти для данного scope. Необратимо.
    ///
    /// - Parameter scope: Область памяти для полного удаления
    /// - Throws: Ошибка SwiftData если удаление не удалось
    public func deleteScope(_ scope: String) throws {
        let context = makeContext()
        guard let entity = try findEntity(scope: scope, in: context) else { return }

        context.delete(entity)
        try context.save()

        print("[MemoryStore] 🗑 Удалён весь scope='\(scope)'")
    }

    // MARK: - Массовая загрузка для system prompt

    /// Загружает записи для нескольких scope одновременно.
    ///
    /// ЗАЧЕМ МАССОВАЯ ЗАГРУЗКА:
    /// buildSystemPrompt() нужно загрузить глобальную память + память нескольких проектов
    /// + тредовую память. Вместо N отдельных запросов к SwiftData — один проход.
    ///
    /// - Parameter scopes: Массив scope для загрузки
    /// - Returns: Словарь [scope: [MemoryEntry]] — записи для каждого scope
    /// - Throws: Ошибка SwiftData если запрос не удался
    public func readEntriesForScopes(_ scopes: [String]) throws -> [String: [MemoryEntry]] {
        let context = makeContext()

        // Загружаем все MemoryEntity одним запросом и фильтруем по нужным scope
        // ПОЧЕМУ НЕ PREDICATE С IN:
        // SwiftData #Predicate не поддерживает оператор IN для массивов строк напрямую.
        // Загружаем все сущности и фильтруем в памяти — для небольшого числа scope
        // (обычно 3-5) это быстрее чем N отдельных запросов.
        let descriptor = FetchDescriptor<MemoryEntity>()
        let allEntities = try context.fetch(descriptor)

        let scopeSet = Set(scopes)
        var result: [String: [MemoryEntry]] = [:]

        for entity in allEntities where scopeSet.contains(entity.scope) {
            result[entity.scope] = entity.entries
        }

        return result
    }

    /// Импортирует массив записей в указанный scope (используется MigrationService в IT-04).
    ///
    /// ЛОГИКА: Создаёт новый scope или заменяет все записи в существующем.
    /// Используется только при миграции — в штатной работе используй saveEntry().
    ///
    /// - Parameters:
    ///   - entries: Записи для импорта
    ///   - scope: Область памяти
    /// - Throws: Ошибка SwiftData если сохранение не удалось
    public func importEntries(_ entries: [MemoryEntry], intoScope scope: String) throws {
        let context = makeContext()
        let entity = try findOrCreateEntity(scope: scope, in: context)
        entity.setEntries(entries)
        try context.save()

        print("[MemoryStore] 📦 Импортировано \(entries.count) записей в scope='\(scope)'")
    }

    // MARK: - Приватные вспомогательные методы

    /// Ищет существующую MemoryEntity для указанного scope.
    ///
    /// - Returns: MemoryEntity или nil если scope не существует
    private func findEntity(scope: String, in context: ModelContext) throws -> MemoryEntity? {
        let descriptor = FetchDescriptor<MemoryEntity>(
            predicate: #Predicate { $0.scope == scope }
        )
        return try context.fetch(descriptor).first
    }

    /// Ищет или создаёт MemoryEntity для указанного scope.
    ///
    /// UPSERT-семантика: если scope не существует — создаём новую сущность.
    /// Новая сущность вставляется в контекст, но NOT сохраняется — caller должен вызвать save().
    ///
    /// - Returns: Существующая или новая MemoryEntity
    private func findOrCreateEntity(scope: String, in context: ModelContext) throws -> MemoryEntity {
        if let existing = try findEntity(scope: scope, in: context) {
            return existing
        }

        // Создаём новый контейнер для этого scope
        let newEntity = MemoryEntity(scope: scope)
        context.insert(newEntity)
        return newEntity
    }
}
