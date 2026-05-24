//
//  AITunnelClient.swift
//  ChappieCore
//
//  Сетевой клиент для работы с API AI-провайдера (AITunnel / OpenAI-совместимый).
//
//  АРХИТЕКТУРНОЕ РЕШЕНИЕ: Структура (struct) вместо класса (class).
//  Причина: AITunnelClient не имеет изменяемого состояния — все свойства константы.
//  Это делает его автоматически Sendable и потокобезопасным в Swift 6 без каких-либо
//  дополнительных аннотаций. Структуры копируются при передаче между акторами,
//  что полностью исключает гонки данных.
//
//  ПОЧЕМУ НЕ ACTOR: Actor нужен, когда есть изменяемое состояние, требующее защиты.
//  Здесь нет никакого состояния — только конфигурация и URLSession, которая сама
//  является потокобезопасной. Использование actor было бы избыточным усложнением.
//
//  PROMPT CACHING (Anthropic через AITunnel):
//  buildMessages() помечает системный промпт тегом `cache_control: {type: "ephemeral"}`.
//  Это говорит Anthropic API закэшировать этот блок на 5 минут.
//  При повторных запросах кэшированные токены стоят ~10% от обычной цены.
//
//  КАК РАБОТАЕТ КЭШИРОВАНИЕ (подтверждено логами):
//  AITunnel пробрасывает статистику кэша через нестандартный объект:
//    prompt_tokens_details.cache_write_tokens — токены записанные в кэш
//    prompt_tokens_details.cached_tokens — токены прочитанные из кэша
//  Это НЕ стандартные поля Anthropic (cache_creation_input_tokens / cache_read_input_tokens),
//  а OpenAI-совместимый формат AITunnel. Парсинг через AIPromptTokensDetails в AITunnelModels.
//  Вычисляемые свойства effectiveCacheRead / effectiveCacheCreation в AIUsage
//  объединяют оба формата в единый интерфейс.
//
//  СТРАТЕГИЯ ТРЁХ BREAKPOINT'ОВ (CACHE-MSG-2):
//
//  Breakpoint 1: системный промпт — стабильный, всегда кэшируется (~2384 токена).
//
//  Breakpoint 2: ПОСЛЕДНИЙ USER-элемент в истории (CACHE-MSG).
//  В агентном цикле последнее сообщение часто role="tool", поэтому ищем
//  последний user-элемент с конца истории. Это кэширует system + всю предшествующую историю.
//
//  Breakpoint 3: ПОСЛЕДНЕЕ СООБЩЕНИЕ в истории (CACHE-MSG-2) — НОВОЕ.
//  Проблема: после breakpoint 2 накапливаются tool-сообщения нового шага цикла.
//  Они не кэшируются, и на каждом следующем шаге пересчитываются заново.
//  Решение: ставим третий breakpoint на самое последнее сообщение истории.
//  Это кэширует "хвост" из tool-ответов текущего шага, который станет
//  стабильным префиксом для следующего шага.
//
//  ПРИМЕР (агентный цикл, шаг 3):
//    system [cache✅]
//    user: "напиши код"
//    assistant: "сейчас"
//    tool: "результат read_file"
//    user: "продолжи" [cache✅]     ← breakpoint 2: последний user
//    assistant: "ещё инструмент"
//    tool: "результат write_file"   ← breakpoint 3: последнее сообщение [cache✅]
//    user: "текущий запрос"         ← добавляется buildContextWindow() (не кэшируется)
//
//  ОЖИДАЕМЫЙ ЭФФЕКТ: created → ~500 tok (только новое сообщение пользователя),
//  read → всё остальное из кэша.
//
//  ЕДИНЫЙ СТРИМИНГОВЫЙ ЦИКЛ (без probe):
//  streamRequestWithTools() — единственный метод, используемый в агентном цикле.
//  Накапливает tool_calls из дельт SSE-потока и возвращает AIStreamResult.

import Foundation

/// Лёгкий и быстрый сетевой клиент для выполнения запросов к API AITunnel.
public struct AITunnelClient: Sendable {

    // MARK: - Константы

    private let endpointURL = URL(string: "https://api.aitunnel.ru/v1/chat/completions")!

    // MARK: - Конфигурация

    private let apiKey: String
    private let modelName: String

    /// Кастомная URLSession с увеличенными таймаутами.
    ///
    /// ПОЧЕМУ НЕ URLSession.shared:
    /// Дефолтный таймаут — 60 секунд. Чаппи может работать минутами.
    private let urlSession: URLSession

    // MARK: - Инициализация

    public init(apiKey: String, modelName: String = "claude-sonnet-4.6") {
        self.apiKey = apiKey
        self.modelName = modelName

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = AppConfig.shared.requestTimeoutSeconds
        config.timeoutIntervalForResource = AppConfig.shared.requestTimeoutSeconds
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Публичный API: обычный запрос (резервный)

    /// Отправляет запрос к языковой модели и возвращает полный ответ одним куском.
    /// Резервный метод — в основном агентном цикле используется streamRequestWithTools().
    public func sendRequest(
        systemPrompt: String,
        chatHistory: [AIMessage],
        tools: [AITool]
    ) async throws -> (message: AIMessage, cost: Double?, balance: Double?) {

        let messages = buildMessages(systemPrompt: systemPrompt, chatHistory: chatHistory)

        let requestBody = AITunnelRequest(
            model: modelName,
            messages: messages,
            temperature: 0.7,
            tools: tools.isEmpty ? nil : tools,
            stream: false
        )

        let request = try buildURLRequest(body: requestBody)
        let (data, response) = try await performRequest(request)
        try validateHTTPResponse(response, data: data)

        let result = try decodeResponse(data)
        logCacheStats(usage: result.usage)

        guard let choice = result.choices.first else {
            throw ChappieError.parsingError("Модель вернула пустой массив choices — ответ отсутствует")
        }

        return (choice.message, result.usage?.cost_rub, result.usage?.balance)
    }

    // MARK: - Публичный API: стриминговый запрос с инструментами (основной метод)

    /// Отправляет стриминговый запрос с поддержкой инструментов и возвращает AIStreamResult.
    ///
    /// КЛЮЧЕВОЕ ОТЛИЧИЕ: Поддерживает инструменты и правильно накапливает
    /// tool_calls из дельт SSE-потока. Один запрос на каждый шаг цикла.
    ///
    /// КАК РАБОТАЕТ НАКОПЛЕНИЕ TOOL_CALLS:
    /// Anthropic API в стриминге отдаёт tool_calls по кусочкам:
    ///   - Первый чанк: id="call_abc", function.name="write_file", function.arguments="{"
    ///   - Последующие: id=nil, function.name=nil, function.arguments="path..."
    /// Накапливаем аргументы по index и собираем полные AIToolCall объекты.
    public func streamRequestWithTools(
        systemPrompt: String,
        chatHistory: [AIMessage],
        tools: [AITool],
        onToken: (@Sendable (String) -> Void)? = nil
    ) async throws -> AIStreamResult {

        let messages = buildMessages(systemPrompt: systemPrompt, chatHistory: chatHistory)

        let requestBody = AITunnelRequest(
            model: modelName,
            messages: messages,
            temperature: 0.7,
            tools: tools.isEmpty ? nil : tools,
            stream: true
        )

        let request = try buildURLRequest(body: requestBody)
        let (asyncBytes, response) = try await urlSession.bytes(for: request)
        try validateHTTPResponse(response, data: nil)

        var accumulatedText = ""
        var toolCallBuffers: [Int: (id: String, name: String, arguments: String)] = [:]
        var finalCost: Double? = nil
        var finalBalance: Double? = nil

        // Читаем SSE-поток построчно
        for try await line in asyncBytes.lines {
            guard !line.isEmpty, line.hasPrefix("data: ") else { continue }

            let jsonString = String(line.dropFirst(6))
            if jsonString == "[DONE]" { break }

            guard let chunkData = jsonString.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(AIStreamChunk.self, from: chunkData) else {
                continue
            }

            // Извлекаем финансовую статистику из последнего чанка
            if let usage = chunk.usage {
                finalCost = usage.cost_rub
                finalBalance = usage.balance
                // Логируем статистику кэша через вычисляемые свойства effectiveCacheRead/Creation
                logCacheStats(usage: usage)
            }

            guard let choice = chunk.choices.first else { continue }
            let delta = choice.delta

            // Текстовые токены — передаём в UI
            if let token = delta.content, !token.isEmpty {
                accumulatedText += token
                onToken?(token)
            }

            // Накопление tool_calls по индексам
            if let streamToolCalls = delta.tool_calls {
                for streamToolCall in streamToolCalls {
                    let idx = streamToolCall.index

                    if var existing = toolCallBuffers[idx] {
                        if let argChunk = streamToolCall.function?.arguments {
                            existing.arguments += argChunk
                            toolCallBuffers[idx] = existing
                        }
                    } else {
                        let id = streamToolCall.id ?? "call_\(idx)"
                        let name = streamToolCall.function?.name ?? ""
                        let args = streamToolCall.function?.arguments ?? ""
                        toolCallBuffers[idx] = (id: id, name: name, arguments: args)
                    }
                }
            }
        }

        // Собираем полные AIToolCall из буферов
        let assembledToolCalls: [AIToolCall]? = toolCallBuffers.isEmpty ? nil :
            toolCallBuffers.sorted(by: { $0.key < $1.key }).compactMap { (_, buffer) in
                guard !buffer.name.isEmpty else { return nil }
                return AIToolCall(
                    id: buffer.id,
                    type: "function",
                    function: AIToolCallFunction(name: buffer.name, arguments: buffer.arguments)
                )
            }

        return AIStreamResult(
            text: accumulatedText,
            toolCalls: assembledToolCalls,
            cost: finalCost,
            balance: finalBalance
        )
    }

    // MARK: - Публичный API: стриминговый запрос без инструментов (устаревший)

    /// Устарел. Используй streamRequestWithTools() вместо этого метода.
    public func streamRequest(
        systemPrompt: String,
        chatHistory: [AIMessage]
    ) -> (stream: AsyncThrowingStream<String, Error>, getUsage: @Sendable () async -> (cost: Double?, balance: Double?)) {

        let usageBox = UsageBox()

        let stream = AsyncThrowingStream<String, Error> { continuation in
            Task {
                do {
                    let usage = try await self.performStreamRequest(
                        systemPrompt: systemPrompt,
                        chatHistory: chatHistory,
                        continuation: continuation
                    )
                    await usageBox.set(usage)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }

        let getUsage: @Sendable () async -> (cost: Double?, balance: Double?) = {
            await usageBox.get()
        }

        return (stream, getUsage)
    }

    // MARK: - Приватные методы: формирование сообщений с кэшированием

    /// Формирует массив сообщений для запроса с расстановкой тегов кэширования.
    ///
    /// СТРАТЕГИЯ ТРЁХ BREAKPOINT'ОВ (CACHE-MSG-2):
    ///
    /// 1. СИСТЕМНЫЙ ПРОМПТ — первый и главный breakpoint.
    ///    Никогда не меняется между запросами. ~2384 токена стабильно.
    ///
    /// 2. ПОСЛЕДНИЙ USER-ЭЛЕМЕНТ — второй breakpoint (CACHE-MSG).
    ///    Кэширует system + всю историю до последнего user-сообщения.
    ///    Работает даже когда последнее сообщение role="tool".
    ///
    /// 3. ПОСЛЕДНЕЕ СООБЩЕНИЕ ИСТОРИИ — третий breakpoint (CACHE-MSG-2).
    ///    Кэширует "хвост" из tool-ответов текущего шага цикла.
    ///    На следующем шаге этот хвост станет стабильным префиксом → будет прочитан из кэша.
    ///
    ///    ВАЖНО: Breakpoint 3 ставится ТОЛЬКО если последнее сообщение ≠ последнему user-сообщению
    ///    (т.е. если между breakpoint 2 и концом истории есть хотя бы одно сообщение).
    ///    Иначе мы бы поставили два breakpoint'а на одно сообщение — бессмысленно.
    ///
    ///    ТАКЖЕ ВАЖНО: Третий breakpoint не ставится на сообщения с tool_calls (assistant),
    ///    т.к. их contentString может быть nil — кэшировать нечего. Ставим только на
    ///    role="tool" (результат инструмента) или role="user" (редкий случай).
    ///
    /// ПРИМЕР (агентный цикл, шаг 3):
    ///   system [cache✅]
    ///   user: "напиши код"
    ///   assistant: "сейчас"
    ///   tool: "результат read_file"
    ///   user: "продолжи" [cache✅]     ← breakpoint 2
    ///   assistant: "ещё инструмент"
    ///   tool: "результат write_file" [cache✅]  ← breakpoint 3
    ///   user: "текущий запрос"        ← добавляется buildContextWindow() (не кэшируется)
    ///
    ///

    // MARK: - Формирование сообщений
        
        private func buildMessages(systemPrompt: String, chatHistory: [AIMessage]) -> [AIMessage] {
            var messages: [AIMessage] = []

            // Передаем системный промпт как обычную строку.
            // Если шлюз поддерживает кэширование, он закэширует его сам автоматически.
            let systemMessage = AIMessage(
                role: "system",
                content: systemPrompt
            )
            messages.append(systemMessage)
            
            // Добавляем историю без модификаций и тегов
            messages.append(contentsOf: chatHistory)
            
            return messages
        }
    
//    private func buildMessages(systemPrompt: String, chatHistory: [AIMessage]) -> [AIMessage] {
//        var messages: [AIMessage] = []
//
//        // ── Breakpoint 1: системный промпт ──────────────────────────────────────
//        // Стабильный, никогда не меняется. ~2384 токена стабильно кэшируются.
//        let systemMessage = AIMessage(
//            role: "system",
//            contentBlocks: [.cached(systemPrompt)]
//        )
//        messages.append(systemMessage)
//
//        guard !chatHistory.isEmpty else {
//            print("[AITunnelClient] 🗃️ Кэш: 1 блок (только system), история пуста")
//            return messages
//        }
//
//        // ── Ищем индексы для breakpoint 2 и 3 ───────────────────────────────────
//
//        // Breakpoint 2: последний user-элемент (ищем с конца истории).
//        // ПОЧЕМУ С КОНЦА: нам нужен самый поздний user-элемент — он максимизирует
//        // кэшируемый префикс. Итерируем reversed() и берём первый найденный.
//        let lastUserIndex = chatHistory.indices.reversed().first { idx in
//            chatHistory[idx].role == "user"
//        }
//
//        // Breakpoint 3: последнее сообщение в истории (если оно отличается от breakpoint 2).
//        // Кэшируем "хвост" из tool-ответов, который накопился после последнего user-сообщения.
//        // ОГРАНИЧЕНИЕ: ставим только на role="tool" или role="user" (у них есть текстовый контент).
//        // role="assistant" с tool_calls имеет contentString=nil → кэшировать нечего.
//        let lastIndex = chatHistory.count - 1
//        let lastMessage = chatHistory[lastIndex]
//        let canCacheLastMessage = (lastMessage.role == "tool" || lastMessage.role == "user")
//            && (lastMessage.contentString != nil && !lastMessage.contentString!.isEmpty)
//
//        // Breakpoint 3 актуален только если последнее сообщение ≠ последнему user-сообщению.
//        // Если они совпадают — breakpoint 2 уже покрывает это сообщение.
//        let useThirdBreakpoint = canCacheLastMessage && lastUserIndex != lastIndex
//
//        // ── Собираем массив сообщений с breakpoint'ами ───────────────────────────
//
//        if let targetIdx = lastUserIndex {
//            // Добавляем все сообщения ДО целевого user-элемента — без кэширования
//            if targetIdx > 0 {
//                messages.append(contentsOf: chatHistory[0..<targetIdx])
//            }
//
//            // ── Breakpoint 2: последний user-элемент ────────────────────────────
//            let targetMessage = chatHistory[targetIdx]
//            if let content = targetMessage.contentString, !content.isEmpty {
//                let cachedMessage = AIMessage(
//                    role: targetMessage.role,
//                    contentBlocks: [.cached(content)],
//                    tool_calls: targetMessage.tool_calls,       // ← сохраняем
//                    tool_call_id: targetMessage.tool_call_id,   // ← сохраняем (критично для role="tool")
//                    name: targetMessage.name                     // ← сохраняем
//                )
//                messages.append(cachedMessage)
//            } else {
//                // Если контент пустой или сложный (tool_calls) — добавляем как есть
//                messages.append(targetMessage)
//            }
//
//            // Добавляем сообщения МЕЖДУ breakpoint 2 и концом истории
//            if targetIdx < chatHistory.count - 1 {
//                let afterUserMessages = chatHistory[(targetIdx + 1)...]
//
//                if useThirdBreakpoint {
//                    // Добавляем все сообщения кроме последнего без кэширования
//                    let withoutLast = afterUserMessages.dropLast()
//                    messages.append(contentsOf: withoutLast)
//
//                    // ── Breakpoint 3: последнее сообщение истории ───────────────
//                    // Кэшируем "хвост" из tool-результатов текущего шага.
//                    // На следующем шаге цикла этот хвост станет стабильным префиксом
//                    // и будет полностью прочитан из кэша → created ≈ 0.
//                    if let content = lastMessage.contentString, !content.isEmpty {
//                        let cachedLast = AIMessage(
//                            role: lastMessage.role,
//                            contentBlocks: [.cached(content)]
//                        )
//                        messages.append(cachedLast)
//                    } else {
//                        messages.append(lastMessage)
//                    }
//                } else {
//                    // Третий breakpoint не нужен — добавляем хвост как есть
//                    messages.append(contentsOf: afterUserMessages)
//                }
//            }
//
//            // Формируем описание для лога
//            let afterCount = chatHistory.count - 1 - targetIdx
//            let bpCount = useThirdBreakpoint ? 3 : 2
//            print("[AITunnelClient] 🗃️ Кэш: \(bpCount) блока (system + user[idx:\(targetIdx)]\(useThirdBreakpoint ? " + last[idx:\(lastIndex)]" : ""), \(afterCount) сообщений после bp2), всего: \(messages.count)")
//
//        } else {
//            // В истории нет ни одного user-сообщения (только tool/assistant).
//            // Это редкий случай, но защищаемся: добавляем историю без кэширования.
//            messages.append(contentsOf: chatHistory)
//            print("[AITunnelClient] 🗃️ Кэш: 1 блок (только system, в истории нет user-сообщений)")
//        }
//
//        return messages
//    }

    /// Логирует статистику кэширования через вычисляемые свойства AIUsage.
    ///
    /// ВАЖНО: Используем effectiveCacheRead / effectiveCacheCreation — они умеют
    /// читать как стандартные поля Anthropic, так и нестандартные поля AITunnel
    /// (prompt_tokens_details.cached_tokens / cache_write_tokens).
    private func logCacheStats(usage: AIUsage?) {
        guard let usage else { return }

        let cacheRead = usage.effectiveCacheRead
        let cacheCreation = usage.effectiveCacheCreation
        let promptTokens = usage.prompt_tokens ?? 0
        let completionTokens = usage.completion_tokens ?? 0
        let costStr = usage.cost_rub.map { String(format: "%.4f ₽", $0) } ?? "н/д"

        if cacheRead > 0 {
            // Экономия: кэшированные токены стоят ~10% от обычной цены → экономим 90%
            let savings = Int(Double(cacheRead) * 0.9)
            print("[AITunnelClient] ✅ Кэш сработал | read: \(cacheRead) tok (сэкономлено ~\(savings) tok) | created: \(cacheCreation) tok | prompt: \(promptTokens) | completion: \(completionTokens) | cost: \(costStr)")
        } else if cacheCreation > 0 {
            print("[AITunnelClient] 🔄 Кэш создан | created: \(cacheCreation) tok | prompt: \(promptTokens) | completion: \(completionTokens) | cost: \(costStr)")
        } else {
            print("[AITunnelClient] ⚠️ Кэш не активен | prompt: \(promptTokens) | completion: \(completionTokens) | cost: \(costStr)")
        }
    }

    // MARK: - Приватные методы: выполнение запросов

    /// Выполняет стриминговый HTTP-запрос и парсит SSE-поток (без инструментов).
    /// Используется устаревшим методом streamRequest().
    private func performStreamRequest(
        systemPrompt: String,
        chatHistory: [AIMessage],
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws -> (cost: Double?, balance: Double?) {

        let messages = buildMessages(systemPrompt: systemPrompt, chatHistory: chatHistory)

        let requestBody = AITunnelRequest(
            model: modelName,
            messages: messages,
            temperature: 0.7,
            tools: nil,
            stream: true
        )

        let request = try buildURLRequest(body: requestBody)
        let (asyncBytes, response) = try await urlSession.bytes(for: request)
        try validateHTTPResponse(response, data: nil)

        var finalCost: Double? = nil
        var finalBalance: Double? = nil

        for try await line in asyncBytes.lines {
            guard !line.isEmpty, line.hasPrefix("data: ") else { continue }

            let jsonString = String(line.dropFirst(6))
            if jsonString == "[DONE]" { break }

            guard let chunkData = jsonString.data(using: .utf8) else { continue }

            let chunk: AIStreamChunk
            do {
                chunk = try JSONDecoder().decode(AIStreamChunk.self, from: chunkData)
            } catch {
                continue
            }

            if let usage = chunk.usage {
                finalCost = usage.cost_rub
                finalBalance = usage.balance
            }

            guard let choice = chunk.choices.first else { continue }

            if let token = choice.delta.content, !token.isEmpty {
                continuation.yield(token)
            }
        }

        return (finalCost, finalBalance)
    }

    /// Формирует URLRequest с правильными заголовками и сериализованным телом.
    private func buildURLRequest(body: AITunnelRequest) throws -> URLRequest {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = AppConfig.shared.requestTimeoutSeconds

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw ChappieError.parsingError("Не удалось сериализовать тело запроса: \(error.localizedDescription)")
        }

        return request
    }

    /// Выполняет URLRequest и возвращает данные + ответ.
    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await urlSession.data(for: request)
        } catch {
            let nsError = error as NSError
            if nsError.code == NSURLErrorTimedOut {
                throw ChappieError.networkError(
                    "Превышено время ожидания ответа (\(Int(AppConfig.shared.requestTimeoutSeconds)) сек). " +
                    "Задача слишком сложная или сервер перегружен. Попробуй разбить задачу на части."
                )
            }
            throw ChappieError.networkError("Ошибка при выполнении запроса: \(error.localizedDescription)")
        }
    }

    /// Проверяет HTTP-статус ответа.
    private func validateHTTPResponse(_ response: URLResponse, data: Data?) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChappieError.networkError("Получен некорректный тип ответа от сервера (не HTTPURLResponse)")
        }

        guard !(200...299).contains(httpResponse.statusCode) else { return }

        let errorBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? "Тело ответа недоступно"

        let isContextError = httpResponse.statusCode == 413
            || errorBody.lowercased().contains("context")
            || errorBody.lowercased().contains("limit")
            || errorBody.lowercased().contains("too long")

        if isContextError {
            throw ChappieError.aiContextLimitExceeded
        }

        throw ChappieError.networkError("HTTP \(httpResponse.statusCode): \(errorBody)")
    }

    /// Декодирует полный (не-стриминговый) ответ API.
    private func decodeResponse(_ data: Data) throws -> AITunnelResponse {
        do {
            return try JSONDecoder().decode(AITunnelResponse.self, from: data)
        } catch {
            throw ChappieError.parsingError("Не удалось декодировать ответ от модели: \(error.localizedDescription)")
        }
    }
}

// MARK: - UsageBox

/// Потокобезопасный контейнер для передачи финансовой статистики из SSE-парсера.
///
/// ЗАЧЕМ НУЖЕН:
/// AsyncThrowingStream.Continuation — Sendable-замыкание, которое не может
/// захватывать изменяемые переменные напрямую. Actor изолирует изменяемое состояние
/// и делает его доступным из любого контекста.
private actor UsageBox {
    private var cost: Double? = nil
    private var balance: Double? = nil

    func set(_ usage: (cost: Double?, balance: Double?)) {
        self.cost = usage.cost
        self.balance = usage.balance
    }

    func get() -> (cost: Double?, balance: Double?) {
        return (cost, balance)
    }
}
