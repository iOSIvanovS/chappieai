// ThreadStore.swift
// ChappieCore
//
// НАЗНАЧЕНИЕ:
// Актор для CRUD-операций над тредами через SwiftData (REFACTOR-THREADS IT-01).
//
// ПОЧЕМУ ACTOR, А НЕ CLASS:
// ThreadStore работает с ModelContext — объектом, который НЕ является Sendable
// и должен использоваться строго на одном потоке. Actor в Swift 6 гарантирует
// последовательный доступ к своему состоянию — это идеальное решение для
// thread-safe обёртки над SwiftData.
//
// ПОЧЕМУ BACKGROUND CONTEXT:
// mainContext изолирован на @MainActor — его нельзя использовать из нашего actor
// без нарушения правил Swift 6 Concurrency. Вместо этого создаём background context
// через ModelContext(modelContainer) — он не привязан к конкретному потоку
// и безопасен для использования внутри actor.
//
// АРХИТЕКТУРА ВЗАИМОДЕЙСТВИЯ:
// UI-слой (ChappieViewModel) → ThreadStore (actor) → SwiftData (ModelContext)
//
// GENERIC-ПОДХОД ДЛЯ СООБЩЕНИЙ:
// ChatMessage определён в Chappie (UI-таргет). ChappieCore не должен от него зависеть.
// Методы saveMessages/loadMessages используют Generic <T: Codable> — аналогично
// уже работающему ChatHistoryManager. UI-слой передаёт конкретный тип.
//
// ИЗМЕНЕНИЕ (IT-06):
// Добавлен метод updateProjectBindings() — атомарная замена всего списка UUID проектов.
// Нужен в ChappieViewModel.addProject() и removeProject() для атомарного обновления
// без риска рассинхронизации при конкурентных изменениях.

import Foundation
import SwiftData

// MARK: - ThreadStore

/// Актор для управления тредами в SwiftData.
///
/// Все методы изолированы в акторе — безопасный конкурентный доступ гарантирован.
/// UI-слой вызывает методы через await.
public actor ThreadStore {

    // MARK: - Свойства

    /// Контейнер модели SwiftData — хранится для создания контекстов.
    ///
    /// ПОЧЕМУ CONTAINER, А НЕ CONTEXT:
    /// ModelContext не является Sendable и не может быть передан между акторами.
    /// ModelContainer — Sendable, его можно безопасно хранить в actor.
    /// Контекст создаётся внутри actor при каждой операции через ModelContext(container).
    private let modelContainer: ModelContainer

    // MARK: - Инициализация

    /// Создаёт ThreadStore с указанным ModelContainer.
    ///
    /// - Parameter modelContainer: Контейнер SwiftData (создаётся в ChappieApp.swift)
    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Вспомогательный метод создания контекста

    /// Создаёт новый ModelContext для операций внутри actor.
    ///
    /// ПОЧЕМУ СОЗДАЁМ КАЖДЫЙ РАЗ:
    /// ModelContext не является Sendable — нельзя хранить его как свойство actor
    /// и передавать между задачами. Создание нового контекста для каждой операции
    /// — стандартная практика для background-операций с SwiftData.
    /// ModelContainer управляет синхронизацией между контекстами автоматически.
    private func makeContext() -> ModelContext {
        ModelContext(modelContainer)
    }

    // MARK: - Создание

    /// Создаёт новый тред и сохраняет его в базе данных.
    ///
    /// - Parameters:
    ///   - title: Название треда (обычно — первые слова первого сообщения)
    ///   - settings: Настройки треда (по умолчанию — дефолтные)
    /// - Returns: UUID созданного треда
    /// - Throws: Ошибка SwiftData если сохранение не удалось
    ///
    /// ПОЧЕМУ ВОЗВРАЩАЕМ UUID, А НЕ ThreadEntity:
    /// ThreadEntity — это @Model объект SwiftData, привязанный к конкретному ModelContext.
    /// Передача его за пределы actor небезопасна в Swift 6. Возвращаем UUID —
    /// caller может загрузить метаданные треда через loadThreads().
    public func createThread(
        title: String,
        settings: ThreadSettings = ThreadSettings()
    ) throws -> UUID {
        let context = makeContext()
        let thread = ThreadEntity(title: title, settings: settings)
        context.insert(thread)
        try context.save()

        print("[ThreadStore] ✅ Создан тред '\(title)' (id: \(thread.id))")
        return thread.id
    }

    // MARK: - Загрузка

    /// Загружает метаданные всех тредов, отсортированных по времени последнего обновления.
    ///
    /// ВОЗВРАЩАЕТ VALUE TYPE:
    /// Возвращаем ThreadMetadata (struct) — безопасный Sendable тип.
    /// Передача @Model объектов за пределы actor небезопасна в Swift 6.
    ///
    /// - Returns: Массив метаданных тредов, отсортированных по updatedAt DESC
    /// - Throws: Ошибка SwiftData если запрос не удался
    public func loadThreads() throws -> [ThreadMetadata] {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let threads = try context.fetch(descriptor)
        return threads.map { ThreadMetadata(from: $0) }
    }

    // MARK: - Обновление сообщений (Generic)

    /// Сохраняет историю сообщений треда.
    ///
    /// GENERIC T: Codable — аналогично ChatHistoryManager.saveMessages<T: Codable>().
    /// ChappieCore не знает о ChatMessage (UI-тип), поэтому принимаем любой Codable.
    /// UI-слой передаёт [ChatMessage], ChappieCore просто сериализует.
    ///
    /// ЛИМИТ: Сохраняем последние 100 сообщений (как в старом ChatHistoryManager).
    ///
    /// - Parameters:
    ///   - messages: Массив сообщений для сохранения (любой Codable тип)
    ///   - threadId: UUID треда, в который сохраняем
    /// - Throws: Ошибка SwiftData или JSONEncoder если сохранение не удалось
    public func saveMessages<T: Codable>(_ messages: [T], toThreadId threadId: UUID) throws {
        let context = makeContext()

        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first else {
            print("[ThreadStore] ⚠️ Тред \(threadId) не найден при сохранении сообщений")
            return
        }

        // Подрезаем до 100 сообщений — UI хранит не больше
        let maxStored = 100
        let trimmed = messages.count > maxStored
            ? Array(messages.suffix(maxStored))
            : messages

        if messages.count > maxStored {
            print("[ThreadStore] ✂️ Подрезание: \(messages.count - maxStored) старых сообщений удалено")
        }

        thread.messagesJSON = try JSONEncoder().encode(trimmed)
        thread.updatedAt = Date()
        try context.save()
    }

    /// Загружает историю сообщений из треда.
    ///
    /// GENERIC T: Codable — UI-слой указывает конкретный тип ([ChatMessage]).
    ///
    /// - Parameters:
    ///   - threadId: UUID треда
    ///   - type: Тип для декодирования (например ChatMessage.self)
    /// - Returns: Массив сообщений (пустой если тред не найден или история пуста)
    /// - Throws: Ошибка SwiftData если запрос не удался
    public func loadMessages<T: Codable>(fromThreadId threadId: UUID, as type: T.Type) throws -> [T] {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first else {
            return []
        }

        guard !thread.messagesJSON.isEmpty else { return [] }

        do {
            return try JSONDecoder().decode([T].self, from: thread.messagesJSON)
        } catch {
            print("[ThreadStore] ⚠️ Ошибка десериализации сообщений треда \(threadId): \(error)")
            return []
        }
    }

    // MARK: - Обновление настроек

    /// Обновляет настройки треда.
    ///
    /// - Parameters:
    ///   - settings: Новые настройки
    ///   - threadId: UUID треда для обновления
    /// - Throws: Ошибка SwiftData если сохранение не удалось
    public func updateSettings(_ settings: ThreadSettings, forThreadId threadId: UUID) throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first else { return }

        thread.settingsJSON = (try? JSONEncoder().encode(settings)) ?? thread.settingsJSON
        try context.save()
    }

    /// Загружает настройки треда.
    ///
    /// - Parameter threadId: UUID треда
    /// - Returns: ThreadSettings (дефолтные если тред не найден или данные повреждены)
    /// - Throws: Ошибка SwiftData если запрос не удался
    public func loadSettings(forThreadId threadId: UUID) throws -> ThreadSettings {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first,
              !thread.settingsJSON.isEmpty,
              let settings = try? JSONDecoder().decode(ThreadSettings.self, from: thread.settingsJSON)
        else {
            return ThreadSettings()
        }
        return settings
    }

    // MARK: - Управление проектами в треде

    /// Загружает список UUID проектов, привязанных к треду.
    ///
    /// - Parameter threadId: UUID треда
    /// - Returns: Массив UUID проектов
    /// - Throws: Ошибка SwiftData если запрос не удался
    public func loadProjectIds(forThreadId threadId: UUID) throws -> [UUID] {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first,
              !thread.projectBindingsJSON.isEmpty,
              let ids = try? JSONDecoder().decode([UUID].self, from: thread.projectBindingsJSON)
        else {
            return []
        }
        return ids
    }

    /// Атомарно заменяет весь список UUID проектов в треде.
    ///
    /// ПОЧЕМУ АТОМАРНАЯ ЗАМЕНА, А НЕ ДОБАВЛЕНИЕ/УДАЛЕНИЕ:
    /// ChappieViewModel хранит актуальный список projectIds в activeThread.
    /// При добавлении или удалении проекта ViewModel вычисляет новый массив
    /// и передаёт его сюда целиком. Это гарантирует консистентность:
    /// нет риска рассинхронизации между тем что видит ViewModel и что в БД.
    ///
    /// АНАЛОГ: saveMessages() — тоже полная замена, не append.
    ///
    /// - Parameters:
    ///   - projectIds: Новый полный список UUID проектов (может быть пустым)
    ///   - threadId: UUID треда для обновления
    /// - Throws: Ошибка SwiftData если сохранение не удалось
    public func updateProjectBindings(_ projectIds: [UUID], forThreadId threadId: UUID) throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first else {
            print("[ThreadStore] ⚠️ Тред \(threadId) не найден при обновлении проектов")
            return
        }

        thread.projectBindingsJSON = (try? JSONEncoder().encode(projectIds)) ?? thread.projectBindingsJSON
        thread.updatedAt = Date()
        try context.save()

        print("[ThreadStore] ✅ Обновлены привязки проектов треда '\(thread.title)': \(projectIds.count) проектов")
    }

    /// Добавляет проект в тред (идемпотентно — дубликаты игнорируются).
    ///
    /// КОГДА ИСПОЛЬЗОВАТЬ:
    /// Для прямого добавления одного проекта без загрузки всего списка.
    /// Для batch-операций предпочтительнее updateProjectBindings().
    ///
    /// - Parameters:
    ///   - projectId: UUID проекта для добавления
    ///   - threadId: UUID треда
    /// - Throws: Ошибка SwiftData если сохранение не удалось
    public func addProject(id projectId: UUID, toThreadId threadId: UUID) throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first else { return }

        var ids: [UUID] = []
        if !thread.projectBindingsJSON.isEmpty {
            ids = (try? JSONDecoder().decode([UUID].self, from: thread.projectBindingsJSON)) ?? []
        }

        guard !ids.contains(projectId) else {
            print("[ThreadStore] ℹ️ Проект \(projectId) уже добавлен в тред '\(thread.title)'")
            return
        }

        ids.append(projectId)
        thread.projectBindingsJSON = (try? JSONEncoder().encode(ids)) ?? thread.projectBindingsJSON
        thread.updatedAt = Date()
        try context.save()

        print("[ThreadStore] ✅ Проект \(projectId) добавлен в тред '\(thread.title)'")
    }

    /// Удаляет проект из треда.
    ///
    /// КОГДА ИСПОЛЬЗОВАТЬ:
    /// Для прямого удаления одного проекта без загрузки всего списка.
    /// Для batch-операций предпочтительнее updateProjectBindings().
    ///
    /// - Parameters:
    ///   - projectId: UUID проекта для удаления
    ///   - threadId: UUID треда
    /// - Throws: Ошибка SwiftData если сохранение не удалось
    public func removeProject(id projectId: UUID, fromThreadId threadId: UUID) throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first else { return }

        var ids: [UUID] = []
        if !thread.projectBindingsJSON.isEmpty {
            ids = (try? JSONDecoder().decode([UUID].self, from: thread.projectBindingsJSON)) ?? []
        }

        let countBefore = ids.count
        ids.removeAll { $0 == projectId }

        guard ids.count < countBefore else {
            print("[ThreadStore] ℹ️ Проект \(projectId) не найден в треде '\(thread.title)'")
            return
        }

        thread.projectBindingsJSON = (try? JSONEncoder().encode(ids)) ?? thread.projectBindingsJSON
        thread.updatedAt = Date()
        try context.save()

        print("[ThreadStore] ✅ Проект \(projectId) удалён из треда '\(thread.title)'")
    }

    // MARK: - Переименование

    /// Переименовывает тред.
    ///
    /// - Parameters:
    ///   - threadId: UUID треда
    ///   - title: Новое название
    /// - Throws: Ошибка SwiftData если сохранение не удалось
    public func renameThread(id threadId: UUID, title: String) throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first else { return }

        thread.title = title
        thread.updatedAt = Date()
        try context.save()
    }

    // MARK: - Удаление

    /// Удаляет тред из базы данных.
    ///
    /// ВНИМАНИЕ: Удаление необратимо. Вся история сообщений треда теряется.
    /// UI должен показывать подтверждение перед вызовом этого метода.
    ///
    /// - Parameter threadId: UUID треда для удаления
    /// - Throws: Ошибка SwiftData если удаление не удалось
    public func deleteThread(id threadId: UUID) throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first else { return }

        let title = thread.title
        context.delete(thread)
        try context.save()

        print("[ThreadStore] 🗑 Тред '\(title)' удалён")
    }
}

// MARK: - ThreadMetadata (Sendable DTO для передачи за пределы actor)

/// Метаданные треда — безопасный Sendable value type для передачи из actor в UI.
///
/// ПОЧЕМУ НЕ ПЕРЕДАЁМ ThreadEntity НАПРЯМУЮ:
/// ThreadEntity — это @Model объект SwiftData. Он привязан к ModelContext и
/// не является Sendable. Передача его из actor в @MainActor UI нарушает
/// правила Swift 6 Concurrency и может вызвать гонки данных.
///
/// ThreadMetadata содержит только примитивы — полностью Sendable.
/// Для мутаций UI передаёт threadId обратно в ThreadStore.
public struct ThreadMetadata: Sendable, Identifiable, Hashable {

    /// UUID треда — используется для всех последующих операций через ThreadStore
    public let id: UUID

    /// Отображаемое название треда
    public let title: String

    /// Время создания
    public let createdAt: Date

    /// Время последнего обновления — используется для сортировки в боковой панели
    public let updatedAt: Date

    /// Список UUID проектов, привязанных к треду
    public let projectIds: [UUID]

    // MARK: - Инициализаторы

    /// Создаёт ThreadMetadata из ThreadEntity (только внутри actor).
    ///
    /// Используется ThreadStore при загрузке тредов из SwiftData.
    init(from entity: ThreadEntity) {
        self.id = entity.id
        self.title = entity.title
        self.createdAt = entity.createdAt
        self.updatedAt = entity.updatedAt

        // Десериализуем список проектов
        if !entity.projectBindingsJSON.isEmpty,
           let ids = try? JSONDecoder().decode([UUID].self, from: entity.projectBindingsJSON) {
            self.projectIds = ids
        } else {
            self.projectIds = []
        }
    }

    /// Публичный memberwise инициализатор — для Preview и тестов.
    ///
    /// ПОЧЕМУ НУЖЕН ПУБЛИЧНЫЙ INIT:
    /// Swift автогенерирует memberwise init как internal для struct.
    /// Для использования в UI-таргете (Chappie) и тестах нужен явный public init.
    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        projectIds: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.projectIds = projectIds
    }
}
