// ThreadModels.swift
// ChappieCore
//
// НАЗНАЧЕНИЕ:
// Модели данных для системы мультитредовости (REFACTOR-THREADS IT-01).
//
// ПРИНЦИП JSON-СЕРИАЛИЗАЦИИ:
// SwiftData хранит только примитивы и Data. Сложные объекты (массивы сообщений,
// настройки треда) сериализуются через JSONEncoder и хранятся как Data.
// При чтении — JSONDecoder. Это полностью избавляет от проблем миграции схемы SwiftData:
// при эволюции модели меняем только Codable-структуры, SwiftData-схема остаётся прежней.
//
// ЗАВИСИМОСТИ:
// - ChatMessage (Chappie/Models/ChatMessage.swift) — используется в ThreadEntity.messagesJSON
// - SwiftData — только в ThreadEntity (финальный класс с @Model)

import Foundation
import SwiftData

// MARK: - ThreadEntity (SwiftData хранилище)

/// Одна запись треда в базе данных SwiftData.
///
/// ПОЧЕМУ ТОЛЬКО ПРИМИТИВЫ И DATA:
/// SwiftData имеет ограниченную поддержку кастомных Codable типов в @Model.
/// Хранение сложных Swift-структур напрямую вызывает проблемы при миграции схемы.
/// Поэтому все сложные объекты сериализуем в Data через JSONEncoder — это даёт
/// полную свободу эволюции без болезненных SwiftData-миграций.
///
/// ПОЧЕМУ @Model FINAL CLASS, А НЕ STRUCT:
/// SwiftData требует reference type для @Model — только классы поддерживают
/// отслеживание изменений через @Observable, которое SwiftData использует под капотом.
@Model
public final class ThreadEntity {

    // MARK: - Идентификация

    /// Уникальный идентификатор треда.
    /// Генерируется при создании и никогда не меняется — это стабильная ссылка.
    public var id: UUID

    /// Отображаемое название треда.
    /// Автогенерируется из первых слов первого сообщения, может быть изменено пользователем.
    public var title: String

    // MARK: - Временные метки

    /// Время создания треда.
    /// Используется для отображения в боковой панели.
    public var createdAt: Date

    /// Время последнего обновления треда.
    /// По этому полю сортируется список тредов (последний активный — сверху).
    public var updatedAt: Date

    // MARK: - JSON-сериализованные данные

    /// История сообщений треда, сериализованная через JSONEncoder.
    /// Тип оригинала: [ChatMessage] (из Chappie/Models/ChatMessage.swift).
    ///
    /// ПОЧЕМУ DATA, А НЕ [ChatMessage]:
    /// ChatMessage — enum с ассоциированными значениями. SwiftData не умеет хранить
    /// такие типы напрямую. Сериализация в Data решает эту проблему полностью.
    public var messagesJSON: Data

    /// Настройки треда, сериализованные через JSONEncoder.
    /// Тип оригинала: ThreadSettings.
    public var settingsJSON: Data

    /// Список UUID проектов, привязанных к этому треду, сериализованный через JSONEncoder.
    /// Тип оригинала: [UUID].
    ///
    /// ПОЧЕМУ СПИСОК UUID, А НЕ ОТНОШЕНИЕ SwiftData:
    /// Отношения SwiftData требуют строгой типизации и вызывают сложности при
    /// каскадном удалении. Список UUID проще и достаточен для нашего случая.
    public var projectBindingsJSON: Data

    // MARK: - Инициализация

    /// Создаёт новый тред с пустой историей и дефолтными настройками.
    ///
    /// - Parameters:
    ///   - id: UUID треда (по умолчанию генерируется новый)
    ///   - title: Название треда
    ///   - settings: Настройки треда (по умолчанию — дефолтные)
    ///   - projectIds: Список UUID привязанных проектов (по умолчанию пустой)
    public init(
        id: UUID = UUID(),
        title: String,
        settings: ThreadSettings = ThreadSettings(),
        projectIds: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()

        // Сериализуем пустую историю, настройки и привязки проектов.
        // Используем безопасную сериализацию с фолбэком на пустой Data.
        self.messagesJSON = (try? JSONEncoder().encode([ChatMessage]())) ?? Data()
        self.settingsJSON = (try? JSONEncoder().encode(settings)) ?? Data()
        self.projectBindingsJSON = (try? JSONEncoder().encode(projectIds)) ?? Data()
    }
}

// MARK: - ThreadSettings (Codable настройки треда)

/// Настройки одного треда — сериализуются в JSON и хранятся в ThreadEntity.settingsJSON.
///
/// ПОЧЕМУ STRUCT, А НЕ @Model:
/// ThreadSettings — это конфигурация, не самостоятельная сущность.
/// Она всегда принадлежит конкретному треду и не нужна независимо от него.
/// Struct + Codable — самый простой и надёжный способ хранить вложенные настройки.
///
/// ПОЧЕМУ НЕ ВСЕ НАСТРОЙКИ ЗДЕСЬ:
/// recentFullMessages, summaryThreshold, maxOrchestratorSteps — технические параметры,
/// которые пользователь не должен видеть. Они остаются захардкоженными в AppConfig.
/// Пользователь управляет только глубиной контекста (maxMessagesInContext).
public struct ThreadSettings: Codable, Sendable, Equatable, Hashable {

    /// Максимальное количество сообщений в контекстном окне.
    ///
    /// ДИАПАЗОН: 10...100
    /// ДЕФОЛТ: 20 (10,000 токенов — разумный баланс)
    ///
    /// ФОРМУЛА tokenBudget:
    /// tokenBudget = maxMessagesInContext × 500
    /// Примеры: 10 → 5,000 | 20 → 10,000 | 50 → 25,000 | 100 → 50,000
    ///
    /// ПОЧЕМУ 500 ТОКЕНОВ НА СООБЩЕНИЕ:
    /// Среднее сообщение в диалоге разработчика — ~200-400 токенов (текст + код).
    /// Коэффициент 500 даёт небольшой запас. При превышении бюджета включается
    /// механизм двойного отсечения (унаследован из buildContextWindow).
    public var maxMessagesInContext: Int

    /// Вычисляемый токенный бюджет на основе количества сообщений.
    ///
    /// НЕ ХРАНИТСЯ В JSON — вычисляется каждый раз.
    /// Это намеренно: изменение формулы не требует миграции данных.
    public var tokenBudget: Int {
        maxMessagesInContext * 500
    }

    /// Создаёт настройки с дефолтными значениями.
    ///
    /// - Parameter maxMessagesInContext: Глубина контекста (10...100, по умолчанию 20)
    public init(maxMessagesInContext: Int = 20) {
        // Зажимаем значение в допустимый диапазон на случай некорректных данных из JSON
        self.maxMessagesInContext = max(10, min(100, maxMessagesInContext))
    }
}

// MARK: - ChatMessage (расширение для JSON-сериализации в ThreadEntity)

// ChatMessage уже является Codable (реализован в Chappie/Models/ChatMessage.swift).
// Здесь мы добавляем удобные методы для сериализации/десериализации массива сообщений
// в контексте ThreadEntity — чтобы не дублировать этот код в ThreadStore.

extension Array where Element == ChatMessage {

    /// Сериализует массив сообщений в Data для хранения в ThreadEntity.messagesJSON.
    ///
    /// Возвращает Data пустого массива при ошибке кодирования.
    /// Ошибка кодирования ChatMessage — это баг в модели, логируем для диагностики.
    public func toJSON() -> Data {
        do {
            return try JSONEncoder().encode(self)
        } catch {
            print("[ThreadModels] ⚠️ Ошибка сериализации сообщений: \(error)")
            return (try? JSONEncoder().encode([ChatMessage]())) ?? Data()
        }
    }

    /// Десериализует массив сообщений из Data (из ThreadEntity.messagesJSON).
    ///
    /// Возвращает пустой массив при ошибке — это безопасный фолбэк.
    /// Ошибка декодирования может означать повреждение данных или изменение модели.
    public static func fromJSON(_ data: Data) -> [ChatMessage] {
        guard !data.isEmpty else { return [] }
        do {
            return try JSONDecoder().decode([ChatMessage].self, from: data)
        } catch {
            print("[ThreadModels] ⚠️ Ошибка десериализации сообщений: \(error)")
            return []
        }
    }
}
