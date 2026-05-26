// MemoryModels.swift
// ChappieCore
//
// НАЗНАЧЕНИЕ:
// Модели данных для трёхуровневой системы памяти (REFACTOR-THREADS IT-01, IT-03, IT-08).
//
// ТРЁХУРОВНЕВАЯ ПАМЯТЬ (IT-08):
// 1. Глобальная (scope = "global") — факты о пользователе, стиль общения, кросс-проектные знания
// 2. Проектная (scope = "<projectId UUID>") — архитектура проекта, пайплайны, договорённости
// 3. Тредовая (scope = "<threadId UUID>") — контекст текущей задачи, временные заметки
//
// АРХИТЕКТУРА SCOPE (IT-08):
// Scope — это строка, которая однозначно идентифицирует уровень памяти:
//   - "global"       → глобальная память (единственная, не зависит от треда/проекта)
//   - "<UUID>"       → память конкретного треда или проекта (UUID в строке)
//
// МАППИНГ ИНСТРУМЕНТОВ (IT-08):
// Инструменты memorize/recall/search_memory/delete_memory работают так:
//   - scope="global"          → пишет/читает scope "global"
//   - scope="thread"          → пишет/читает scope UUID активного треда
//   - targetName="Chappie"    → пишет/читает scope UUID проекта по имени среди прикреплённых
//
// РАЗРЕШЕНИЕ КОНФЛИКТОВ (IT-08):
// Если глобальная память противоречит проектной или тредовой —
// Чаппи останавливается, объясняет конфликт пользователю и ждёт решения.
//
// ПОЧЕМУ ОДНА ТАБЛИЦА ДЛЯ ВСЕХ УРОВНЕЙ:
// Все три уровня имеют одинаковую структуру — список записей (key/value/type).
// Разделение по scope через строку — проще и гибче чем три отдельные таблицы.
// Добавление нового уровня памяти = просто новый формат scope-строки.
//
// МИГРАЦИЯ:
// Существующие данные из ~/Documents/Chappie/semantic.json переносятся в
// MemoryEntity с scope="global" сервисом MigrationService (IT-04).

import Foundation
import SwiftData

// MARK: - ActiveMemoryContext (IT-08)

/// Описание активного контекста памяти — передаётся в ToolExecutionService.
///
/// ЗАЧЕМ ОТДЕЛЬНАЯ СТРУКТУРА (IT-08):
/// Раньше ToolExecutionService хранил только [String] имён проектов — для PROJECT GUARD.
/// Теперь нужно знать UUID треда и UUID+имя каждого проекта — для маппинга scope памяти.
/// ActiveMemoryContext инкапсулирует всё это в одном Sendable value type.
///
/// МНОГИЕ-КО-МНОГИМ (IT-08):
/// Тред и проекты не владеют друг другом — это связь без владения.
/// Один проект может быть в нескольких тредах, один тред может иметь несколько проектов.
/// Глобальная память — единственная, кто "владеет всем".
public struct ActiveMemoryContext: Sendable {

    /// Информация об одном проекте в контексте: UUID + отображаемое имя.
    ///
    /// ПОЧЕМУ UUID + ИМЯ:
    /// UUID нужен для маппинга scope в MemoryStore.
    /// Имя нужно для поиска проекта по targetName из инструментов Чаппи.
    public struct ProjectInfo: Sendable {
        public let id: UUID
        public let name: String

        public init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// UUID активного треда (для тредовой памяти).
    /// nil = нет активного треда, тредовая память недоступна.
    public let threadId: UUID?

    /// Список проектов, прикреплённых к активному треду.
    /// Пустой = нет проектов, проектная память недоступна.
    public let projects: [ProjectInfo]

    public init(threadId: UUID? = nil, projects: [ProjectInfo] = []) {
        self.threadId = threadId
        self.projects = projects
    }

    /// Пустой контекст — без треда и проектов.
    /// Используется как фолбэк до инициализации ModelContainer.
    public static let empty = ActiveMemoryContext(threadId: nil, projects: [])

    /// Удобный геттер: есть ли хотя бы один проект.
    /// Используется в PROJECT GUARD — блокировке файловых инструментов без проекта.
    public var hasProjects: Bool { !projects.isEmpty }

    /// Имена проектов для логирования и сообщений об ошибках.
    public var projectNames: [String] { projects.map { $0.name } }

    /// UUID всех проектов — для buildSystemPrompt() в MemoryManager.
    public var projectIds: [UUID] { projects.map { $0.id } }
}

// MARK: - MemoryEntity (SwiftData хранилище)

/// Контейнер записей памяти для одного scope (уровня).
///
/// ОДИН ОБЪЕКТ = ОДИН УРОВЕНЬ ПАМЯТИ.
/// Например: одна MemoryEntity для scope="global", одна для scope="<projectId>".
///
/// ПОЧЕМУ НЕ ХРАНИТЬ КАЖДУЮ ЗАПИСЬ ОТДЕЛЬНО:
/// Отдельная строка на каждую запись памяти создала бы тысячи строк в таблице.
/// Массив записей в одном JSON компактнее и быстрее читается целиком —
/// а нам нужно всегда читать ВСЕ записи уровня для подмешивания в system prompt.
@Model
public final class MemoryEntity {

    // MARK: - Идентификация

    /// Уникальный идентификатор контейнера памяти.
    public var id: UUID

    /// Уровень/область памяти.
    ///
    /// ФОРМАТЫ SCOPE (IT-08):
    /// - "global"       — глобальная кросс-проектная память
    /// - "<projectId>"  — память конкретного проекта (UUID в строке)
    /// - "<threadId>"   — память конкретного треда (UUID в строке)
    ///
    /// ИНДЕКСИРОВАНИЕ: Поиск по scope — основная операция, поэтому это поле
    /// должно быть проиндексировано (SwiftData делает это автоматически для @Model).
    public var scope: String

    // MARK: - JSON-сериализованные записи

    /// Записи памяти, сериализованные через JSONEncoder.
    /// Тип оригинала: [MemoryEntry].
    ///
    /// ПОЧЕМУ DATA:
    /// MemoryEntry содержит поле metadata типа [String: String] — SwiftData
    /// не умеет хранить Dictionary напрямую. Data + JSONEncoder решает это элегантно.
    public var entriesJSON: Data

    // MARK: - Временные метки

    /// Время последнего обновления контейнера памяти.
    /// Используется для отладки и диагностики.
    public var updatedAt: Date

    // MARK: - Инициализация

    /// Создаёт новый контейнер памяти для указанного scope.
    ///
    /// - Parameters:
    ///   - id: UUID контейнера (по умолчанию генерируется новый)
    ///   - scope: Уровень памяти ("global", UUID проекта или UUID треда)
    ///   - entries: Начальный список записей (по умолчанию пустой)
    public init(
        id: UUID = UUID(),
        scope: String,
        entries: [MemoryEntry] = []
    ) {
        self.id = id
        self.scope = scope
        self.updatedAt = Date()
        self.entriesJSON = (try? JSONEncoder().encode(entries)) ?? Data()
    }
}

// MARK: - MemoryEntry (одна запись памяти)

/// Одна запись в памяти Чаппи — аналог строки в таблице key-value хранилища.
///
/// СОВМЕСТИМОСТЬ С СУЩЕСТВУЮЩИМ MemoryManager:
/// Текущий MemoryManager работает с файлом semantic.json, где каждая запись имеет
/// поля key, type, jsonString. MemoryEntry воспроизводит эту структуру для
/// бесшовной миграции (MigrationService, IT-04).
public struct MemoryEntry: Codable, Sendable, Identifiable, Equatable {

    /// Уникальный идентификатор записи.
    public let id: UUID

    /// Ключ записи — уникален в рамках одного scope.
    /// Примеры: "user_name", "pipeline_rules", "current_task"
    public var key: String

    /// Тип записи — для категоризации и фильтрации.
    /// Примеры: "fact", "rule", "persona", "project_map", "pipeline"
    public var type: String

    /// Содержимое записи в формате JSON-строки.
    ///
    /// ПОЧЕМУ JSON-СТРОКА, А НЕ ПРЯМЫЕ ПОЛЯ:
    /// Разные типы записей имеют разную структуру данных.
    /// Хранение в виде JSON-строки даёт гибкость без изменения схемы.
    /// Это наследуется из существующего MemoryManager (semantic.json).
    public var jsonString: String

    /// Дополнительные метаданные записи (опционально).
    /// Используется для хранения вспомогательной информации (дата создания, источник и т.д.)
    public var metadata: [String: String]?

    /// Время создания записи.
    public var createdAt: Date

    /// Время последнего обновления записи.
    public var updatedAt: Date

    // MARK: - Инициализация

    /// Создаёт новую запись памяти.
    ///
    /// - Parameters:
    ///   - id: UUID записи (по умолчанию генерируется новый)
    ///   - key: Уникальный ключ в рамках scope
    ///   - type: Тип записи (fact, rule, persona и т.д.)
    ///   - jsonString: Содержимое в формате JSON-строки
    ///   - metadata: Дополнительные метаданные (опционально)
    public init(
        id: UUID = UUID(),
        key: String,
        type: String,
        jsonString: String,
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.key = key
        self.type = type
        self.jsonString = jsonString
        self.metadata = metadata
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - MemoryEntity вспомогательные методы

extension MemoryEntity {

    /// Десериализует список записей из entriesJSON.
    ///
    /// Возвращает пустой массив при ошибке — безопасный фолбэк.
    public var entries: [MemoryEntry] {
        guard !entriesJSON.isEmpty,
              let decoded = try? JSONDecoder().decode([MemoryEntry].self, from: entriesJSON)
        else {
            return []
        }
        return decoded
    }

    /// Сериализует и сохраняет новый список записей в entriesJSON.
    ///
    /// - Parameter newEntries: Новый список записей для сохранения
    ///
    /// ВАЖНО: После вызова этого метода SwiftData автоматически отслеживает изменение
    /// и сохранит его при следующем save() контекста.
    public func setEntries(_ newEntries: [MemoryEntry]) {
        if let data = try? JSONEncoder().encode(newEntries) {
            entriesJSON = data
            updatedAt = Date()
        } else {
            print("[MemoryModels] ⚠️ Ошибка сериализации записей памяти для scope='\(scope)'")
        }
    }

    /// Форматирует содержимое памяти в читаемый текстовый блок для подмешивания в system prompt.
    ///
    /// ФОРМАТ ВЫВОДА:
    /// ```
    /// ## Память [глобальная/проектная/тредовая]
    /// - [тип] ключ: содержимое
    /// - [тип] ключ: содержимое
    /// ```
    ///
    /// ЗАЧЕМ ФОРМАТИРОВАНИЕ:
    /// ИИ лучше воспринимает структурированный текст. Явные заголовки и маркеры
    /// помогают модели понять контекст каждой записи.
    ///
    /// - Parameter title: Заголовок блока памяти (например "Глобальная память")
    /// - Returns: Отформатированный текст или nil если записей нет
    public func formatForPrompt(title: String) -> String? {
        let currentEntries = entries
        guard !currentEntries.isEmpty else { return nil }

        var lines = ["## \(title)"]
        for entry in currentEntries {
            // Пытаемся извлечь читаемое значение из JSON-строки
            let displayValue: String
            if let data = entry.jsonString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = json.values.first {
                displayValue = "\(value)"
            } else {
                // Если JSON не парсится — показываем как есть
                displayValue = entry.jsonString
            }
            lines.append("- [\(entry.type)] \(entry.key): \(displayValue)")
        }

        return lines.joined(separator: "\n")
    }
}
