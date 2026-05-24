// ChatMessage.swift
// Chappie
//
// ПОЧЕМУ ЭТОТ ФАЙЛ СУЩЕСТВУЕТ:
// Ранее ChatMessage был struct прямо в ChappieViewModel.swift и нёс две разные роли:
//   1. Обычное сообщение пользователя или ИИ (текст, стоимость)
//   2. Технический лог вызова инструмента (эмодзи-строка "🛠 Выполняю: write_file -> ...")
// Смешение ролей в одном типе — классический запах кода. MessageBubbleView не мог
// рендерить их по-разному, история чата засорялась техническими строками,
// фильтрация в ViewModel была хрупкой (проверка по содержимому строки!).
//
// РЕШЕНИЕ (ТД-6):
// ChatMessage становится enum с двумя семантически чёткими кейсами.
// MessageBubbleView теперь знает, что именно рендерить — и делает это красиво.
//
// ИЗМЕНЕНИЕ (ТД-COST-SUMMARY — Self-Summary):
// В кейс .message добавлено поле `summary: String?`.
// Это краткая выжимка ответа Чаппи, извлечённая из тега <summary>...</summary>.
// При подготовке истории для API: если summary есть и сообщение "старое" (вне
// свежего окна) — вместо полного текста подставляется summary. Это радикально
// сокращает количество токенов без потери смысла контекста.
//
// ПОЧЕМУ ПОЛЕ В МОДЕЛИ, А НЕ В VIEWMODEL:
// Summary — это неотъемлемая часть сообщения. Оно должно сохраняться на диск
// вместе с остальными данными сообщения, чтобы быть доступным при следующем
// запуске приложения. Хранить его в ViewModel отдельно — значит создавать
// хрупкую синхронизацию двух источников истины.

import Foundation

/// Единица истории чата — либо текстовое сообщение, либо лог вызова инструмента.
///
/// Зачем enum, а не struct с флагом: Enum с ассоциированными значениями
/// делает невозможным создание "некорректного" состояния. Нельзя случайно
/// создать сообщение с `isToolCall: true` и при этом заполнить поле `cost`.
/// Компилятор сам следит за корректностью через exhaustive switch.
public enum ChatMessage: Identifiable, Hashable, Codable {

    // MARK: - Кейсы

    /// Обычное текстовое сообщение — от пользователя или от ИИ.
    ///
    /// - isUser: true = пользователь (справа, синий), false = Чаппи (слева, нейтральный)
    /// - text: Текст сообщения (поддерживает Markdown через TextSelection).
    ///   Для ответов Чаппи: полный текст БЕЗ тега <summary> (он уже извлечён и скрыт).
    /// - cost: Стоимость запроса в рублях — только у финальных ответов ИИ
    /// - summary: Краткая выжимка ответа (1-3 предложения), извлечённая из тега <summary>.
    ///   nil для сообщений пользователя и коротких ответов без тега.
    ///   Используется при подготовке истории для API вместо полного текста.
    case message(id: UUID = UUID(), isUser: Bool, text: String, cost: Double? = nil, summary: String? = nil)

    /// Лог вызова инструмента — технический шаг агентного цикла.
    ///
    /// Зачем хранить в истории: Пользователю важно видеть "мыслительный процесс"
    /// Чаппи — какие файлы он читал, что писал. Это прозрачность и доверие.
    /// Но при подготовке контекста для API эти записи фильтруются — модели
    /// не нужно знать о своих же инструментах из прошлых шагов.
    ///
    /// - toolName: Имя инструмента ("write_file", "read_file", "memorize" и т.д.)
    /// - targetPath: Путь к файлу или ключ памяти (пустая строка если нет)
    case toolCall(id: UUID = UUID(), toolName: String, targetPath: String)

    // MARK: - Identifiable

    /// Уникальный идентификатор — нужен для ForEach и ScrollViewReader.scrollTo()
    public var id: UUID {
        switch self {
        case .message(let id, _, _, _, _): return id
        case .toolCall(let id, _, _): return id
        }
    }

    // MARK: - Удобные вычисляемые свойства

    /// Является ли это сообщением пользователя (для фильтрации при подготовке контекста API)
    public var isUser: Bool {
        switch self {
        case .message(_, let isUser, _, _, _): return isUser
        case .toolCall: return false
        }
    }

    /// Текст сообщения — только для кейса .message, иначе nil
    public var text: String? {
        switch self {
        case .message(_, _, let text, _, _): return text
        case .toolCall: return nil
        }
    }

    /// Стоимость запроса — только для финальных ответов ИИ
    public var cost: Double? {
        switch self {
        case .message(_, _, _, let cost, _): return cost
        case .toolCall: return nil
        }
    }

    /// Краткая выжимка ответа для подстановки в историю API.
    ///
    /// Присутствует только у ответов Чаппи (isUser == false) и только
    /// если модель добавила тег <summary> в конце ответа.
    public var summary: String? {
        switch self {
        case .message(_, _, _, _, let summary): return summary
        case .toolCall: return nil
        }
    }

    /// Является ли это логом вызова инструмента
    public var isToolCall: Bool {
        if case .toolCall = self { return true }
        return false
    }

    // MARK: - Codable (ручная реализация для enum с ассоциированными значениями)

    // Зачем ручная реализация: Swift не умеет автоматически синтезировать Codable
    // для enum с ассоциированными значениями, если нужен конкретный формат JSON.
    // Мы хотим сохранять историю в читаемом формате, совместимом со старыми версиями.

    private enum CodingKeys: String, CodingKey {
        case type, id, isUser, text, cost, summary, toolName, targetPath
    }

    private enum MessageType: String, Codable {
        case message, toolCall
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(MessageType.self, forKey: .type) ?? .message
        let id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()

        switch type {
        case .message:
            let isUser = try container.decode(Bool.self, forKey: .isUser)
            let text = try container.decode(String.self, forKey: .text)
            let cost = try container.decodeIfPresent(Double.self, forKey: .cost)
            // summary декодируется опционально — старые записи без этого поля
            // будут иметь summary == nil, что полностью корректно
            let summary = try container.decodeIfPresent(String.self, forKey: .summary)
            self = .message(id: id, isUser: isUser, text: text, cost: cost, summary: summary)

        case .toolCall:
            let toolName = try container.decode(String.self, forKey: .toolName)
            let targetPath = try container.decodeIfPresent(String.self, forKey: .targetPath) ?? ""
            self = .toolCall(id: id, toolName: toolName, targetPath: targetPath)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .message(let id, let isUser, let text, let cost, let summary):
            try container.encode(MessageType.message, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(isUser, forKey: .isUser)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(cost, forKey: .cost)
            // Сохраняем summary только если он есть — экономим место в JSON
            try container.encodeIfPresent(summary, forKey: .summary)

        case .toolCall(let id, let toolName, let targetPath):
            try container.encode(MessageType.toolCall, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(toolName, forKey: .toolName)
            try container.encode(targetPath, forKey: .targetPath)
        }
    }
}
