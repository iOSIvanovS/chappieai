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
//
//  ИЗМЕНЕНИЕ (TOP-LEVEL-CACHE — Автоматическое кэширование через top-level cache_control):
//  Добавлено поле `cache_control: AICacheControl?` в AITunnelRequest.
//  Это top-level поле (рядом с model, messages) — AITunnel шлюз сам управляет
//  брейкпоинтом по мере роста диалога. Никаких per-block cache_control в сообщениях.
//  TTL 1 час — оптимально для длинных сессий разработки.

import Foundation

// MARK: - Prompt Caching: Content Blocks

/// Управляющий тег кэширования — используется как top-level поле в AITunnelRequest.
///
/// ПОЧЕМУ TOP-LEVEL, А НЕ PER-BLOCK:
/// AITunnel — OpenAI-совместимый шлюз. Поле `content` в сообщениях ОБЯЗАНО быть строкой.
/// Если передать массив объектов с cache_control внутри сообщений — шлюз ломает соединение.
/// Правильный способ — top-level cache_control в теле запроса. Шлюз сам двигает
/// брейкпоинт по мере роста диалога (sticky routing).
///
/// ПОЧЕМУ TTL 1 ЧАС:
/// Сессии разработки с Чаппи длятся часами. Дефолтный TTL 5 минут означает, что
/// системный промпт (тысячи токенов) пересчитывается каждые 5 минут простоя.
/// С TTL 1 час кэш живёт через перерывы и экономит до 90% стоимости системного промпта.
public struct AICacheControl: Codable, Sendable {
    /// Тип кэша. На момент написания поддерживается только "ephemeral".
    public let type: String
    /// Время жизни кэша. "1h" = 1 час, nil = 5 минут (по умолчанию).
    public let ttl: String?

    /// Стандартный кэш на 5 минут (для per-block использования, если потребуется).
    public init(type: String = "ephemeral", ttl: String? = nil) {
        self.type = type
        self.ttl = ttl
    }

    /// Фабричный метод: кэш на 1 час — оптимально для длинных сессий разработки.
    public static let oneHour = AICacheControl(type: "ephemeral", ttl: "1h")

    /// Фабричный метод: кэш на 5 минут (по умолчанию).
    public static let fiveMinutes = AICacheControl(type: "ephemeral", ttl: nil)
}

/// Один блок контента в сообщении — текст с опциональным тегом кэширования.
///
/// ЗАЧЕМ БЛОКИ ВМЕСТО СТРОКИ:
/// Стандартный OpenAI-формат использует `content: String`. Но Anthropic расширил
/// протокол: `content` может быть массивом объектов `[{type, text, cache_control?}]`.
/// Только через этот формат можно пометить контент для кэширования.
///
/// ВАЖНО: Эта структура сохранена для совместимости с декодированием ответов API.
/// В запросах мы НЕ используем per-block cache_control — только top-level в AITunnelRequest.
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
/// API принимает оба формата. Для всех сообщений используем строку — она компактнее
/// и гарантированно совместима с AITunnel шлюзом. Массив блоков сохранён для
/// декодирования ответов, которые теоретически могут прийти в расширенном формате.
public enum AIMessageContent: Sendable {
    /// Простая строка — для всех сообщений в запросах к AITunnel.
    case text(String)
    /// Массив блоков — для декодирования ответов в расширенном формате.
    case blocks([AIContentBlock])
}

extension AIMessageContent: Encodable {
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let string):
            // Кодируем как обычную строку — стандартный OpenAI-формат, совместимый с AITunnel
            var container = encoder.singleValueContainer()
            try container.encode(string)
        case .blocks(let blocks):
            // Кодируем как массив объектов — расширенный Anthropic-формат.
            // ВНИМАНИЕ: НЕ использовать в запросах к AITunnel — шлюз не принимает массивы.
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
/// ПОЛЕ cache_control (TOP-LEVEL CACHING):
/// Это ключевое поле для автоматического кэширования промптов через AITunnel.
/// Размещается на верхнем уровне запроса (рядом с model, messages) — это НЕ то же самое,
/// что per-block cache_control внутри сообщений.
///
/// Как это работает:
/// 1. Мы передаём `cache_control: {"type": "ephemeral", "ttl": "1h"}` в теле запроса.
/// 2. AITunnel включает sticky routing: повторные запросы с тем же диалогом идут
///    к тому же провайдеру (Anthropic), где уже есть кэш.
/// 3. Шлюз сам двигает брейкпоинт по мере роста диалога — нам ничего делать не нужно.
/// 4. Экономия: системный промпт Чаппи (~3000+ токенов) стоит 10% при cache hit.
///
/// ПОЛЕ stream:
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
    /// Top-level кэш-контроль для автоматического кэширования промптов.
    ///
    /// ПОЧЕМУ TOP-LEVEL, А НЕ ВНУТРИ СООБЩЕНИЙ:
    /// AITunnel требует именно этот формат для автоматического multi-turn кэширования.
    /// Per-block cache_control внутри content[] ломает OpenAI-совместимый шлюз.
    /// С TTL 1h кэш живёт через перерывы в сессии.
    public let cache_control: AICacheControl?

    public init(
        model: String,
        messages: [AIMessage],
        temperature: Double? = nil,
        tools: [AITool]? = nil,
        stream: Bool = false,
        cacheControl: AICacheControl? = .oneHour
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.tools = tools
        self.stream = stream
        self.cache_control = cacheControl
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
///
/// ПРАВИЛО ДЛЯ AITunnel:
/// Поле content в сообщениях ВСЕГДА должно быть строкой (.text), НИКОГДА .blocks.
/// Кэширование — через top-level cache_control в AITunnelRequest, не здесь.
public struct AIMessage: Codable, Sendable {
    public var role: String
    /// Полиморфный контент: строка или массив блоков с cache_control.
    /// В запросах к AITunnel — ВСЕГДА строка. Блоки — только для декодирования ответов.
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

    /// Инициализатор с блоками — сохранён для совместимости, но НЕ использовать в запросах.
    ///
    /// ВНИМАНИЕ: Этот инициализатор создаёт сообщение с .blocks контентом.
    /// Такой формат НЕ совместим с AITunnel шлюзом при отправке запросов.
    /// Использовать только для тестирования или если AITunnel явно поддержит per-block кэш.
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
