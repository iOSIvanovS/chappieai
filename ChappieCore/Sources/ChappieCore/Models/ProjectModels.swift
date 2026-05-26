// ProjectModels.swift
// ChappieCore
//
// НАЗНАЧЕНИЕ:
// Модели данных для проектов в системе мультитредовости (REFACTOR-THREADS IT-01).
//
// ПРИНЦИП:
// ProjectEntity хранится в SwiftData только с примитивами и Data.
// ProjectSettings — Codable struct, сериализуется в settingsJSON.
//
// ЗАЧЕМ SECURITY-SCOPED BOOKMARK:
// macOS sandbox запрещает прямой доступ к произвольным папкам.
// Security-scoped bookmark — это постоянный токен доступа, который:
// 1. Создаётся один раз при выборе папки пользователем (через NSOpenPanel)
// 2. Сохраняется в базе данных
// 3. При каждом запуске приложения "разрешается" обратно в URL с правами доступа
// Без bookmarkData приложение потеряет доступ к папке проекта после перезапуска.

import Foundation
import SwiftData

// MARK: - ProjectEntity (SwiftData хранилище)

/// Одна запись проекта в базе данных SwiftData.
///
/// Проект = папка на диске (воркспейс) + настройки.
/// Один проект может быть привязан к нескольким тредам одновременно.
///
/// ПОЧЕМУ BOOKMARK, А НЕ ПУТЬ:
/// Абсолютный путь ненадёжен — пользователь может переименовать папку или переместить её.
/// Security-scoped bookmark отслеживает папку по inode, а не по пути.
/// Это стандартная практика для sandbox-приложений на macOS.
@Model
public final class ProjectEntity {

    // MARK: - Идентификация

    /// Уникальный идентификатор проекта.
    public var id: UUID

    /// Отображаемое имя проекта (обычно — имя папки).
    /// Пользователь видит это имя в чипах и списке проектов.
    public var displayName: String

    // MARK: - Доступ к файловой системе

    /// Security-scoped bookmark для доступа к папке проекта.
    ///
    /// КАК ИСПОЛЬЗОВАТЬ:
    /// 1. `let url = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, ...)`
    /// 2. `url.startAccessingSecurityScopedResource()`
    /// 3. ... работаем с файлами ...
    /// 4. `url.stopAccessingSecurityScopedResource()`
    ///
    /// ВАЖНО: startAccessingSecurityScopedResource() должен быть сбалансирован с stop!
    /// Иначе произойдёт утечка ресурсов (kernel resource leak).
    public var bookmarkData: Data

    // MARK: - Временные метки

    /// Время добавления проекта.
    public var createdAt: Date

    // MARK: - JSON-сериализованные настройки

    /// Настройки проекта, сериализованные через JSONEncoder.
    /// Тип оригинала: ProjectSettings.
    public var settingsJSON: Data

    // MARK: - Инициализация

    /// Создаёт новую запись проекта.
    ///
    /// - Parameters:
    ///   - id: UUID проекта (по умолчанию генерируется новый)
    ///   - displayName: Отображаемое имя проекта
    ///   - bookmarkData: Security-scoped bookmark для доступа к папке
    ///   - settings: Настройки проекта (по умолчанию — дефолтные)
    public init(
        id: UUID = UUID(),
        displayName: String,
        bookmarkData: Data,
        settings: ProjectSettings = ProjectSettings()
    ) {
        self.id = id
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.createdAt = Date()
        self.settingsJSON = (try? JSONEncoder().encode(settings)) ?? Data()
    }
}

// MARK: - ProjectSettings (Codable настройки проекта)

/// Настройки одного проекта — сериализуются в JSON и хранятся в ProjectEntity.settingsJSON.
///
/// ТЕКУЩИЕ НАСТРОЙКИ:
/// Пока минимальный набор. В будущих итерациях сюда добавятся:
/// - язык комментариев кода
/// - язык архитектурных файлов
/// - режим (подсказчик vs программист)
/// - доступные инструменты (git, тесты, компиляция)
/// - пайплайны (обсуждаются в треде и записываются в память)
///
/// ПОЧЕМУ STRUCT:
/// Настройки — это value type. Нет смысла делать их reference type.
/// Codable + Hashable даёт бесплатную сериализацию и использование в Set/Dictionary.
public struct ProjectSettings: Codable, Sendable, Equatable, Hashable {

    /// Предпочтительный язык для общения в контексте этого проекта.
    ///
    /// ФОРМАТ: BCP 47 language tag, например "ru", "en", "de".
    /// ДЕФОЛТ: nil означает "использовать язык системы".
    ///
    /// ПОЧЕМУ ОПЦИОНАЛЬНЫЙ STRING, А НЕ ENUM:
    /// Enum потребовал бы миграции при добавлении нового языка.
    /// String + nil даёт гибкость без миграции данных.
    public var preferredLanguage: String?

    /// Создаёт настройки с дефолтными значениями.
    public init(preferredLanguage: String? = nil) {
        self.preferredLanguage = preferredLanguage
    }
}

// MARK: - ProjectEntity вспомогательные методы

extension ProjectEntity {

    /// Десериализует настройки проекта из settingsJSON.
    ///
    /// Возвращает дефолтные настройки при ошибке — безопасный фолбэк.
    public var settings: ProjectSettings {
        guard !settingsJSON.isEmpty,
              let decoded = try? JSONDecoder().decode(ProjectSettings.self, from: settingsJSON)
        else {
            return ProjectSettings()
        }
        return decoded
    }

    /// Разрешает bookmark и возвращает URL воркспейса.
    ///
    /// ВАЖНО: Вызывающий код ОБЯЗАН вызвать url.stopAccessingSecurityScopedResource()
    /// после завершения работы с файлами!
    ///
    /// - Returns: URL папки проекта или nil если bookmark устарел/недействителен
    public func resolveWorkspaceURL() -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            print("[ProjectModels] ⚠️ Не удалось разрешить bookmark для проекта '\(displayName)'")
            return nil
        }

        if isStale {
            // Bookmark устарел (папка была перемещена/переименована).
            // TODO [IT-06]: обновить bookmark через NSOpenPanel при следующем доступе
            print("[ProjectModels] ⚠️ Bookmark устарел для проекта '\(displayName)'. Требуется переавторизация.")
        }

        return url
    }
}
