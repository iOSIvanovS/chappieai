// ProjectStore.swift
// ChappieCore
//
// НАЗНАЧЕНИЕ:
// Актор для CRUD-операций над проектами через SwiftData (REFACTOR-THREADS IT-01).
//
// РОЛЬ В АРХИТЕКТУРЕ:
// ProjectStore управляет списком известных проектов (воркспейсов).
// Каждый проект хранит security-scoped bookmark для доступа к папке.
// Треды ссылаются на проекты по UUID (в projectBindingsJSON).
//
// ПОЧЕМУ BACKGROUND CONTEXT:
// Аналогично ThreadStore — используем ModelContext(modelContainer) вместо mainContext,
// чтобы избежать нарушения правил Swift 6 (@MainActor isolation).
//
// СВЯЗЬ С СУЩЕСТВУЮЩИМ КОДОМ:
// Сейчас выбор воркспейса хранится в UserDefaults через SettingsManager.
// После IT-05 (UI тредов) воркспейс будет выбираться через ProjectStore.
// Существующий SettingsManager остаётся как фолбэк до полной миграции.

import Foundation
import SwiftData

// MARK: - ProjectStore

/// Актор для управления проектами в SwiftData.
///
/// Все методы изолированы в акторе — безопасный конкурентный доступ гарантирован.
public actor ProjectStore {

    // MARK: - Свойства

    /// Контейнер модели SwiftData — хранится для создания контекстов.
    private let modelContainer: ModelContainer

    // MARK: - Инициализация

    /// Создаёт ProjectStore с указанным ModelContainer.
    ///
    /// - Parameter modelContainer: Контейнер SwiftData (создаётся в ChappieApp.swift)
    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Вспомогательный метод создания контекста

    /// Создаёт новый ModelContext для операций внутри actor.
    ///
    /// ModelContainer является Sendable — его можно безопасно хранить в actor.
    /// ModelContext создаётся для каждой операции и не передаётся за пределы метода.
    private func makeContext() -> ModelContext {
        ModelContext(modelContainer)
    }

    // MARK: - Создание

    /// Добавляет новый проект в базу данных.
    ///
    /// - Parameters:
    ///   - displayName: Отображаемое имя проекта (обычно — имя папки)
    ///   - bookmarkData: Security-scoped bookmark для доступа к папке проекта
    ///   - settings: Настройки проекта (по умолчанию — дефолтные)
    /// - Returns: UUID созданного проекта
    /// - Throws: Ошибка SwiftData если сохранение не удалось
    ///
    /// ПОЧЕМУ ВОЗВРАЩАЕМ UUID:
    /// Аналогично ThreadStore — ProjectEntity не является Sendable,
    /// возвращаем UUID для безопасной передачи в UI.
    public func addProject(
        displayName: String,
        bookmarkData: Data,
        settings: ProjectSettings = ProjectSettings()
    ) throws -> UUID {
        let context = makeContext()

        let project = ProjectEntity(
            displayName: displayName,
            bookmarkData: bookmarkData,
            settings: settings
        )
        context.insert(project)
        try context.save()

        print("[ProjectStore] ✅ Добавлен проект '\(displayName)' (id: \(project.id))")
        return project.id
    }

    // MARK: - Загрузка

    /// Загружает метаданные всех проектов, отсортированных по дате создания.
    ///
    /// - Returns: Массив метаданных проектов
    /// - Throws: Ошибка SwiftData если запрос не удался
    public func loadProjects() throws -> [ProjectMetadata] {
        let context = makeContext()
        let descriptor = FetchDescriptor<ProjectEntity>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let projects = try context.fetch(descriptor)
        return projects.map { ProjectMetadata(from: $0) }
    }

    /// Загружает метаданные конкретного проекта по его UUID.
    ///
    /// - Parameter id: UUID проекта
    /// - Returns: ProjectMetadata или nil если проект не найден
    /// - Throws: Ошибка SwiftData если запрос не удался
    public func loadProject(id: UUID) throws -> ProjectMetadata? {
        let context = makeContext()
        let descriptor = FetchDescriptor<ProjectEntity>(
            predicate: #Predicate { $0.id == id }
        )
        guard let project = try context.fetch(descriptor).first else { return nil }
        return ProjectMetadata(from: project)
    }

    /// Загружает метаданные проектов по списку UUID.
    ///
    /// - Parameter ids: Список UUID проектов
    /// - Returns: Массив найденных ProjectMetadata (порядок соответствует ids)
    /// - Throws: Ошибка SwiftData если запрос не удался
    public func loadProjects(ids: [UUID]) throws -> [ProjectMetadata] {
        guard !ids.isEmpty else { return [] }

        let context = makeContext()
        let all = try context.fetch(FetchDescriptor<ProjectEntity>())
        let metadataMap = Dictionary(uniqueKeysWithValues: all.map { ($0.id, ProjectMetadata(from: $0)) })

        // Сохраняем порядок из ids
        return ids.compactMap { metadataMap[$0] }
    }

    /// Загружает security-scoped bookmark для проекта.
    ///
    /// Используется при смене активного проекта — нужен bookmark для resolveWorkspaceURL().
    ///
    /// - Parameter id: UUID проекта
    /// - Returns: Data с bookmark или nil если проект не найден
    /// - Throws: Ошибка SwiftData если запрос не удался
    public func loadBookmark(forProjectId id: UUID) throws -> Data? {
        let context = makeContext()
        let descriptor = FetchDescriptor<ProjectEntity>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first?.bookmarkData
    }

    // MARK: - Обновление

    /// Обновляет настройки проекта.
    ///
    /// - Parameters:
    ///   - settings: Новые настройки
    ///   - projectId: UUID проекта для обновления
    /// - Throws: Ошибка SwiftData если сохранение не удалось
    public func updateSettings(_ settings: ProjectSettings, forProjectId projectId: UUID) throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ProjectEntity>(
            predicate: #Predicate { $0.id == projectId }
        )
        guard let project = try context.fetch(descriptor).first else { return }

        project.settingsJSON = (try? JSONEncoder().encode(settings)) ?? project.settingsJSON
        try context.save()

        print("[ProjectStore] ✅ Обновлены настройки проекта '\(project.displayName)'")
    }

    /// Обновляет bookmark проекта (при устаревании).
    ///
    /// - Parameters:
    ///   - bookmarkData: Новый security-scoped bookmark
    ///   - projectId: UUID проекта для обновления
    /// - Throws: Ошибка SwiftData если сохранение не удалось
    public func updateBookmark(_ bookmarkData: Data, forProjectId projectId: UUID) throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ProjectEntity>(
            predicate: #Predicate { $0.id == projectId }
        )
        guard let project = try context.fetch(descriptor).first else { return }

        project.bookmarkData = bookmarkData
        try context.save()

        print("[ProjectStore] ✅ Обновлён bookmark для проекта '\(project.displayName)'")
    }

    /// Переименовывает проект.
    ///
    /// - Parameters:
    ///   - projectId: UUID проекта
    ///   - name: Новое имя
    /// - Throws: Ошибка SwiftData если сохранение не удалось
    public func renameProject(id projectId: UUID, name: String) throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ProjectEntity>(
            predicate: #Predicate { $0.id == projectId }
        )
        guard let project = try context.fetch(descriptor).first else { return }

        project.displayName = name
        try context.save()
    }

    // MARK: - Удаление

    /// Удаляет проект из базы данных.
    ///
    /// ВАЖНО: Удаление проекта НЕ удаляет треды, которые на него ссылаются.
    /// UUID удалённого проекта просто перестаёт резолвиться в ProjectMetadata.
    /// UI должен обрабатывать этот случай (показывать "Проект удалён" вместо имени).
    ///
    /// - Parameter projectId: UUID проекта для удаления
    /// - Throws: Ошибка SwiftData если удаление не удалось
    public func deleteProject(id projectId: UUID) throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ProjectEntity>(
            predicate: #Predicate { $0.id == projectId }
        )
        guard let project = try context.fetch(descriptor).first else { return }

        let name = project.displayName
        context.delete(project)
        try context.save()

        print("[ProjectStore] 🗑 Проект '\(name)' удалён")
    }
}

// MARK: - ProjectMetadata (Sendable DTO для передачи за пределы actor)

/// Метаданные проекта — безопасный Sendable value type для передачи из actor в UI.
///
/// АНАЛОГ ThreadMetadata: ProjectEntity не является Sendable, поэтому
/// передаём только примитивы. Для операций с файлами UI запрашивает
/// bookmark через loadBookmark(forProjectId:).
public struct ProjectMetadata: Sendable, Identifiable, Hashable {

    /// UUID проекта
    public let id: UUID

    /// Отображаемое имя проекта
    public let displayName: String

    /// Время добавления проекта
    public let createdAt: Date

    /// Настройки проекта
    public let settings: ProjectSettings

    /// Создаёт ProjectMetadata из ProjectEntity (только внутри actor).
    init(from entity: ProjectEntity) {
        self.id = entity.id
        self.displayName = entity.displayName
        self.createdAt = entity.createdAt
        self.settings = entity.settings
    }
}
