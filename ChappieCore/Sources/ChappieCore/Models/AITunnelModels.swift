//
//  AITunnelModels.swift
//  ChappieCore
//
//  Codable/Sendable модели для работы с API AITunnel (OpenAI-совместимый протокол
//  с расширениями Anthropic — в частности, Prompt Caching).
//
//  ИЗМЕНЕНИЕ (ТД-7 — Стриминг):
//  Добавлено поле `stream` в AITunnelRequest и новые модели для разбора SSE-чанков.
//
//  ИЗМЕНЕНИЕ (ТД-COST — Prompt Caching):
//  Добавлены типы AIContentBlock и AIMessageContent для поддержки кэширования промптов.
//  Anthropic позволяет пометить блоки контента флагом `cache_control: {type: "ephemeral"}`.
//  Такие блоки кэшируются на 5 минут и при повторных запросах стоят ~10% от обычной цены.
//  Это критически важно: системный промпт Чаппи — огромный и отправляется с КАЖДЫМ запросом.
//
//  ИЗМЕНЕНИЕ (SINGLE-STREAM — Единый стриминговый цикл):
//  Добавлен инициализатор AIMessage(role:content:toolCalls:) для создания сообщений
//  с tool_calls из стримингового буфера. Это нужно для нового подхода без probe-запроса.
//
//  ИЗМЕНЕНИЕ (CACHE-PARSE — Парсинг кэша AITunnel):
//  AITunnel использует нестандартные имена полей для статистики кэша:
//    - Стандарт Anthropic: cache_creation_input_tokens, cache_read_input_tokens (верхний уровень)
//    - AITunnel: prompt_tokens_details.cache_write_tokens, prompt_tokens_details.cached_tokens
//  Добавлена структура AIPromptTokensDetails для парсинга вложенного объекта.
//  Вычисляемые свойства в AIUsage обеспечивают единый интерфейс для logCacheStats.

import Foundation

// MARK: - Prompt Caching: Content Blocks

/// Управляющий тег кэширования — сигнализирует Anthropic API, что этот блок нужно закэшировать.
///
/// ПОЧЕМУ EPHEMERAL:
/// Единственный поддерживаемый тип кэша на данный момент. "Эфемерный" означает
/// кэш живёт 5 минут с момента последнего использования. Для нашего сценария
/// (активная разработка, запросы идут часто) это идеально.
public struct AICacheControl: Codable, Sendable {
    /// Тип кэша. На момент написания Anthropic поддерживает только "ephemeral".
    public let type: String

    public init(type: String = "ephemeral") {
        self.type = type
    }
}

/// Один блок контента в сообщении — текст с опциональным тегом кэширования.
///
/// ЗАЧЕМ БЛОКИ ВМЕСТО СТРОКИ:
/// Стандартный OpenAI-формат использует `content: String`. Но Anthropic расширил
/// протокол: `content` может быть массивом объектов `[{type, text, cache_control?}]`.
/// Только через этот формат можно пометить контент для кэширования.
///
/// КОГДА ИСПОЛЬЗУЕМ:
/// - Системный промпт → всегда помечаем `cache_control`, т.к. он огромный и постоянный.
/// - Последнее сообщение пользователя → помечаем, т.к. история до него уже в кэше.
/// - Остальные сообщения → оставляем строкой (не нужно кэшировать промежуточные шаги).
public struct AIContentBlock: Codable, Sendable {
    /// Тип блока. Для текста всегда "text".
    public let type: String
    /// Текстовое содержимое блока.
    public let text: String
    /// Опциональный тег кэширования. Если nil — блок не кэшируется.
    public let cache_control: AICacheControl?

    public init(text: String, cacheControl: AICacheControl? = nil) {
        self.type = "text"
        self.text = text
        self.cache_control = cacheControl
    }

    /// Удобный фабричный метод для создания кэшируемого блока.
    public static func cached(_ text: String) -> AIContentBlock {
        AIContentBlock(text: text, cacheControl: AICacheControl())
    }

    /// Удобный фабричный метод для создания обычного (некэшируемого) блока.
    public static func plain(_ text: String) -> AIContentBlock {
        AIContentBlock(text: text, cacheControl: nil)
    }
}

/// Полиморфный контент сообщения: либо простая строка, либо массив блоков.
///
/// ЗАЧЕМ ENUM:
/// API принимает оба формата. Для большинства сообщений (история, ответы инструментов)
/// достаточно строки — она компактнее и не требует лишней обёртки.
/// Для системного промпта и последнего сообщения пользователя нужны блоки с cache_control.
///
/// Кастомный Encodable позволяет нам прозрачно сериализовать оба варианта
/// в правильный JSON без дублирования логики в каждом месте использования.
public enum AIMessageContent: Sendable {
    /// Простая строка — для обычных сообщений без кэширования.
    case text(String)
    /// Массив блоков — для сообщений с поддержкой кэширования.
    case blocks([AIContentBlock])
}

extension AIMessageContent: Encodable {
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let string):
            // Кодируем как обычную строку — стандартный OpenAI-формат
            var container = encoder.singleValueContainer()
            try container.encode(string)
        case .blocks(let blocks):
            // Кодируем как массив объектов — расширенный Anthropic-формат с cache_control
            var container = encoder.singleValueContainer()
            try container.encode(blocks)
        }
    }
}

extension AIMessageContent: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Сначала пробуем декодировать как строку (наиболее частый случай в ответах API)
        if let string = try? container.decode(String.self) {
            self = .text(string)
        } else if let blocks = try? container.decode([AIContentBlock].self) {
            self = .blocks(blocks)
        } else {
            // Если ни то ни другое — считаем пустой строкой, не падаем
            self = .text("")
        }
    }
}

// MARK: - Request Models

/// Тело POST-запроса к API AI-провайдера.
///
/// Поле `stream` добавлено для поддержки SSE-стриминга:
/// - `stream = false` (по умолчанию) → обычный блокирующий ответ
/// - `stream = true`  → сервер возвращает поток `data: {...}\n\n` чанков
public struct AITunnelRequest: Encodable, Sendable {
    public let model: String
    public let messages: [AIMessage]
    public let temperature: Double?
    public let tools: [AITool]?
    /// Включает SSE-стриминг (Server-Sent Events).
    /// При true сервер начинает отдавать токены немедленно по мере генерации.
    public let stream: Bool

    public init(
        model: String,
        messages: [AIMessage],
        temperature: Double? = nil,
        tools: [AITool]? = nil,
        stream: Bool = false
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.tools = tools
        self.stream = stream
    }
}

/// Единичное сообщение в диалоге (роль + контент + опциональные поля).
///
/// ИЗМЕНЕНИЕ (ТД-COST):
/// Поле `content` теперь `AIMessageContent?` вместо `String?`.
/// `AIMessageContent` — enum, который прозрачно кодируется либо как строка,
/// либо как массив блоков. Это позволяет помечать отдельные сообщения для кэширования
/// без изменения всей остальной логики.
///
/// Добавлено вычисляемое свойство `contentString` для обратной совместимости —
/// все места, которые читают текст ответа модели, продолжают работать без изменений.
///
/// ИЗМЕНЕНИЕ (SINGLE-STREAM):
/// Добавлен инициализатор с параметром `toolCalls: [AIToolCall]` — используется
/// в AIOrchestrator при создании сообщения из стримингового буфера с tool_calls.
public struct AIMessage: Codable, Sendable {
    public var role: String
    /// Полиморфный контент: строка или массив блоков с cache_control.
    public var content: AIMessageContent?
    public var tool_calls: [AIToolCall]?
    public var tool_call_id: String?
    public var name: String?

    /// Удобный доступ к тексту контента без разбора enum вручную.
    ///
    /// ЗАЧЕМ: Многие места в коде (AIOrchestrator, ChatHistoryManager и др.) читают
    /// `message.content` как строку. Это свойство даёт им обратную совместимость:
    /// не нужно везде писать `if case .text(let s) = message.content`.
    public var contentString: String? {
        guard let content else { return nil }
        switch content {
        case .text(let s): return s
        case .blocks(let blocks): return blocks.map(\.text).joined()
        }
    }

    /// Инициализатор со строкой — для обратной совместимости со всем существующим кодом.
    /// Большинство мест создают AIMessage(role:content:) — они продолжают работать.
    public init(
        role: String,
        content: String? = nil,
        tool_calls: [AIToolCall]? = nil,
        tool_call_id: String? = nil,
        name: String? = nil
    ) {
        self.role = role
        self.content = content.map { .text($0) }
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
        self.name = name
    }

    /// Инициализатор с блоками — для создания кэшируемых сообщений.
    /// Используется в AITunnelClient при формировании системного промпта
    /// и последнего сообщения пользователя.
    public init(
        role: String,
        contentBlocks: [AIContentBlock],
        tool_calls: [AIToolCall]? = nil,
        tool_call_id: String? = nil,
        name: String? = nil
    ) {
        self.role = role
        self.content = .blocks(contentBlocks)
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
        self.name = name
    }

    /// Инициализатор для создания assistant-сообщения с tool_calls из стримингового буфера.
    ///
    /// ЗАЧЕМ ОТДЕЛЬНЫЙ ИНИЦИАЛИЗАТОР:
    /// В новом едином стриминговом цикле (без probe-запроса) AIOrchestrator накапливает
    /// ответ модели в текстовом буфере и после завершения потока создаёт AIMessage
    /// для добавления в историю сессии. Этот инициализатор делает создание такого
    /// сообщения явным и семантически понятным.
    ///
    /// ПОЧЕМУ content И toolCalls одновременно:
    /// В стриминговом режиме модель может вернуть и текст и tool_calls в одном ответе
    /// (например, "Сейчас сделаю это..." + вызов инструмента). Оба поля опциональны.
    public init(
        role: String,
        content: String?,
        toolCalls: [AIToolCall]?,
        tool_call_id: String? = nil,
        name: String? = nil
    ) {
        self.role = role
        self.content = content.map { .text($0) }
        self.tool_calls = toolCalls
        self.tool_call_id = tool_call_id
        self.name = name
    }
}

// MARK: - Functions and Schemas (Function Calling)

public struct AITool: Codable, Sendable {
    public let type: String
    public let function: AIFunctionDefinition

    public init(type: String = "function", function: AIFunctionDefinition) {
        self.type = type
        self.function = function
    }
}

public struct AIFunctionDefinition: Codable, Sendable {
    public let name: String
    public let description: String
    public let parameters: AIToolParameters

    public init(name: String, description: String, parameters: AIToolParameters) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct AIToolParameters: Codable, Sendable {
    public var type: String = "object" // 🔥 КЛОД ТРЕБУЕТ ЭТО ПОЛЕ ВСЕГДА!
    public let properties: [String: AIToolProperty]
    public let required: [String]?
    
    public init(type: String = "object", properties: [String: AIToolProperty], required: [String]? = nil) {
        self.type = type
        self.properties = properties
        self.required = required
    }
}

public struct AIToolProperty: Codable, Sendable {
    public let type: String
    public let description: String?

    public init(type: String, description: String?) {
        self.type = type
        self.description = description
    }
}

// MARK: - Response Models (Non-Streaming)

/// Полный ответ API при обычном (не-стриминговом) запросе.
public struct AITunnelResponse: Decodable, Sendable {
    public let id: String?
    public let choices: [AIChoice]
    public let usage: AIUsage?
}

/// Один вариант ответа модели (обычно choices[0]).
public struct AIChoice: Decodable, Sendable {
    public let message: AIMessage
    public let finish_reason: String?
}

// MARK: - Cache Statistics

/// Детализация токенов промпта — вложенный объект `prompt_tokens_details`.
///
/// ПОЧЕМУ ОТДЕЛЬНАЯ СТРУКТУРА:
/// AITunnel отдаёт статистику кэша НЕ на верхнем уровне usage (как стандартный Anthropic),
/// а вложенным объектом prompt_tokens_details. Это нестандартное расширение провайдера.
///
/// Стандарт Anthropic:
///   { "cache_creation_input_tokens": 2414, "cache_read_input_tokens": 2384 }
///
/// AITunnel:
///   { "prompt_tokens_details": { "cache_write_tokens": 2414, "cached_tokens": 2384 } }
///
/// Структура парсит оба варианта для совместимости.
public struct AIPromptTokensDetails: Decodable, Sendable {
    /// Токены, записанные в кэш в этом запросе (AITunnel-специфичное поле).
    public let cache_write_tokens: Int?
    /// Токены, прочитанные из кэша (AITunnel-специфичное поле).
    public let cached_tokens: Int?
    /// Аудио-токены (не используется, но парсим для полноты).
    public let audio_tokens: Int?
    /// Видео-токены (не используется, но парсим для полноты).
    public let video_tokens: Int?
}

/// Статистика использования токенов и финансовая информация.
///
/// ИЗМЕНЕНИЕ (ТД-COST — Prompt Caching):
/// Добавлены поля для парсинга статистики кэша.
///
/// ИЗМЕНЕНИЕ (CACHE-PARSE):
/// AITunnel использует нестандартные имена полей — через вложенный объект
/// `prompt_tokens_details`. Добавлено поле `prompt_tokens_details: AIPromptTokensDetails?`.
/// Вычисляемые свойства `effectiveCacheCreation` и `effectiveCacheRead` объединяют
/// оба варианта (стандартный Anthropic + AITunnel) в единый интерфейс.
public struct AIUsage: Decodable, Sendable {
    public let prompt_tokens: Int?
    public let completion_tokens: Int?
    public let total_tokens: Int?
    public let cost_rub: Double?
    public let balance: Double?

    /// Стандартные поля Anthropic (могут отсутствовать у AITunnel).
    /// Токены, записанные в кэш в этом запросе (стоят x1.25 от обычной цены).
    public let cache_creation_input_tokens: Int?
    /// Токены, прочитанные из кэша (стоят x0.1 от обычной цены).
    public let cache_read_input_tokens: Int?

    /// Нестандартный объект AITunnel с детализацией кэша.
    public let prompt_tokens_details: AIPromptTokensDetails?

    // MARK: - Вычисляемые свойства для единого интерфейса

    /// Токены, записанные в кэш — работает и с Anthropic, и с AITunnel форматом.
    ///
    /// ПРИОРИТЕТ: Сначала смотрим на стандартное поле Anthropic,
    /// если нет — берём из вложенного объекта AITunnel.
    public var effectiveCacheCreation: Int {
        if let standard = cache_creation_input_tokens, standard > 0 { return standard }
        return prompt_tokens_details?.cache_write_tokens ?? 0
    }

    /// Токены, прочитанные из кэша — работает и с Anthropic, и с AITunnel форматом.
    ///
    /// ПРИОРИТЕТ: Сначала смотрим на стандартное поле Anthropic,
    /// если нет — берём из вложенного объекта AITunnel.
    public var effectiveCacheRead: Int {
        if let standard = cache_read_input_tokens, standard > 0 { return standard }
        return prompt_tokens_details?.cached_tokens ?? 0
    }
}

// MARK: - Tool Call Models

public struct AIToolCall: Codable, Sendable {
    public var id: String
    public var type: String
    public var function: AIToolCallFunction

    public init(id: String, type: String, function: AIToolCallFunction) {
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct AIToolCallFunction: Codable, Sendable {
    public var name: String
    public var arguments: String

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}

// MARK: - Streaming Models (SSE)

/// Один чанк SSE-потока.
///
/// Сервер отдаёт поток строк вида:
///   data: {"id":"...","choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}\n\n
///   data: [DONE]\n\n
///
/// Каждая такая строка (кроме [DONE]) декодируется в AIStreamChunk.
/// Поле `usage` присутствует только в последнем чанке перед [DONE] —
/// именно оттуда берём стоимость и баланс.
public struct AIStreamChunk: Decodable, Sendable {
    public let id: String?
    public let choices: [AIStreamChoice]
    /// Статистика токенов — приходит только в финальном чанке.
    public let usage: AIUsage?
}

/// Один вариант ответа внутри SSE-чанка.
public struct AIStreamChoice: Decodable, Sendable {
    /// Дельта-обновление: новые токены или начало tool_call.
    public let delta: AIStreamDelta
    /// "stop" означает конец генерации, nil — продолжение.
    public let finish_reason: String?
}

/// Дельта-обновление: приращение текста или вызов инструмента.
///
/// ПОЧЕМУ ДВА ОПЦИОНАЛЬНЫХ ПОЛЯ:
/// Модель генерирует либо текст (`content`), либо вызов инструмента (`tool_calls`),
/// но никогда оба сразу. Первый чанк с tool_call содержит id и name,
/// последующие чанки — только `arguments` (JSON накапливается постепенно).
public struct AIStreamDelta: Decodable, Sendable {
    /// Новые токены текста (nil если это tool_call чанк).
    public let content: String?
    /// Вызовы инструментов — приходят частями, нужно накапливать.
    public let tool_calls: [AIStreamToolCall]?
}

/// Частичный вызов инструмента из SSE-потока.
///
/// В отличие от AIToolCall (полный, из не-стримингового ответа),
/// этот объект приходит по кусочкам:
///   - Первый чанк: id="call_abc", function.name="write_file", function.arguments="{"
///   - Последующие: id=nil, function.name=nil, function.arguments="path"
/// Поэтому index обязателен — по нему накапливаем аргументы в правильный слот.
public struct AIStreamToolCall: Decodable, Sendable {
    /// Порядковый номер tool_call (для параллельных вызовов).
    public let index: Int
    /// ID вызова — присутствует только в первом чанке этого tool_call.
    public let id: String?
    /// Тип — обычно "function", присутствует только в первом чанке.
    public let type: String?
    /// Частичные данные функции.
    public let function: AIStreamToolCallFunction?
}

/// Частичные данные функции из SSE-потока.
public struct AIStreamToolCallFunction: Decodable, Sendable {
    /// Имя функции — только в первом чанке.
    public let name: String?
    /// Кусочек JSON-аргументов — накапливается по чанкам.
    public let arguments: String?
}

// MARK: - Streaming Result

/// Полный результат стримингового запроса с поддержкой инструментов.
///
/// ЗАЧЕМ ОТДЕЛЬНАЯ СТРУКТУРА:
/// streamRequestWithTools() должен вернуть не только поток токенов,
/// но и собранные tool_calls (которые приходят по кусочкам в дельтах).
/// Эта структура агрегирует всё что накопилось за время потока.
public struct AIStreamResult: Sendable {
    /// Накопленный текстовый ответ (пустой если был только tool_call).
    public let text: String
    /// Собранные вызовы инструментов (nil если был только текстовый ответ).
    public let toolCalls: [AIToolCall]?
    /// Стоимость запроса в рублях.
    public let cost: Double?
    /// Обновлённый баланс после запроса.
    public let balance: Double?
}
