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

import Foundation

/// Лёгкий и быстрый сетевой клиент для выполнения запросов к API AITunnel.
///
/// Инкапсулирует всю логику формирования HTTP-запроса, сериализации/десериализации
/// и обработки ошибок сети. Бизнес-логика (оркестрация, инструменты) не знает,
/// как именно работает сеть — это классический принцип разделения ответственности.
public struct AITunnelClient: Sendable {

    // MARK: - Константы

    /// URL конечной точки API AITunnel.
    /// Вынесен в константу, а не захардкожен в методе, чтобы легко менять провайдера
    /// в одном месте без поиска по всему файлу.
    private let endpointURL = URL(string: "https://api.aitunnel.ru/v1/chat/completions")!

    // MARK: - Конфигурация

    /// API-ключ для авторизации запросов.
    /// Передаётся снаружи (из ViewModel/ToolExecutionService), а не хранится внутри клиента,
    /// чтобы клиент оставался переиспользуемым и не знал об источнике ключа.
    private let apiKey: String

    /// Имя языковой модели, которую будет использовать этот экземпляр клиента.
    /// По умолчанию — Claude Sonnet 4.6 как основная модель Чаппи.
    private let modelName: String

    /// Кастомная URLSession с увеличенными таймаутами.
    ///
    /// ПОЧЕМУ НЕ URLSession.shared:
    /// URLSession.shared использует системный дефолтный таймаут — 60 секунд на запрос.
    /// Этого достаточно для простых HTTP-запросов, но Чаппи работает иначе: один reasoning
    /// loop может занимать несколько минут (инспекция проекта, рефакторинг, работа с памятью).
    /// Кастомная сессия с таймаутом 300 секунд решает проблему таймаутов раз и навсегда.
    ///
    /// URLSession является потокобезопасной (Sendable), поэтому хранение её в struct
    /// не нарушает требований Swift 6 по конкурентности.
    private let urlSession: URLSession

    // MARK: - Инициализация

    /// Создаёт экземпляр клиента с кастомными таймаутами из AppConfig.
    ///
    /// - Parameters:
    ///   - apiKey: API-ключ для доступа к AITunnel.
    ///   - modelName: Имя модели. По умолчанию `claude-sonnet-4.6` — текущая основная модель Чаппи.
    ///     Параметр оставлен открытым, чтобы в будущем можно было легко переключать модели
    ///     (например, для A/B-тестирования или работы с разными провайдерами).
    public init(apiKey: String, modelName: String = "claude-sonnet-4.6") {
        self.apiKey = apiKey
        self.modelName = modelName

        // Создаём кастомную конфигурацию URLSession с увеличенными таймаутами.
        // timeoutIntervalForRequest  — максимальное время ожидания ответа от сервера.
        // timeoutIntervalForResource — максимальное суммарное время всей операции (загрузка и т.д.).
        // Оба берём из AppConfig, чтобы тюнинг происходил в одном месте.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = AppConfig.shared.requestTimeoutSeconds
        config.timeoutIntervalForResource = AppConfig.shared.requestTimeoutSeconds

        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Публичный API

    /// Отправляет запрос к языковой модели и возвращает ответное сообщение.
    ///
    /// Метод полностью обрабатывает весь сетевой цикл: формирование запроса,
    /// отправка, проверка HTTP-статуса, декодирование ответа.
    ///
    /// - Parameters:
    ///   - systemPrompt: Системная инструкция для модели (роль, правила поведения).
    ///     Всегда добавляется первым сообщением с ролью "system".
    ///   - chatHistory: История предыдущих сообщений диалога для поддержания контекста.
    ///     Добавляется после системного промпта.
    ///   - tools: Массив инструментов (функций), которые модель может вызывать.
    ///     Если массив пуст — поле `tools` не включается в запрос (экономия токенов).
    ///
    /// - Returns: Кортеж из трёх значений:
    ///   - `message`: Ответное сообщение от модели (может содержать текст или вызовы инструментов).
    ///   - `cost`: Стоимость запроса в рублях (если провайдер возвращает эту информацию).
    ///   - `balance`: Текущий остаток баланса в рублях (если провайдер возвращает).
    ///
    /// - Throws: `ChappieError.networkError` при сетевых проблемах или ошибках HTTP.
    ///           `ChappieError.parsingError` при невозможности декодировать ответ.
    ///           `ChappieError.aiContextLimitExceeded` если контекст превышен (HTTP 413 или аналог).
    public func sendRequest(
        systemPrompt: String,
        chatHistory: [AIMessage],
        tools: [AITool]
    ) async throws -> (message: AIMessage, cost: Double?, balance: Double?) {

        // Формируем полный массив сообщений: системный промпт + история диалога.
        // Системный промпт всегда идёт первым — это требование OpenAI-совместимых API.
        var messages = [AIMessage(role: "system", content: systemPrompt)]
        messages.append(contentsOf: chatHistory)

        // Собираем тело запроса.
        // tools передаём только если они есть — это экономит токены и упрощает ответ модели
        // в случаях, когда Function Calling не нужен.
        let requestBody = AITunnelRequest(
            model: modelName,
            messages: messages,
            temperature: 0.7,
            tools: tools.isEmpty ? nil : tools
        )

        // Конфигурируем HTTP-запрос.
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        // Формат "Bearer <ключ>" — стандарт авторизации для OpenAI-совместимых API.
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // Явно задаём таймаут и на уровне URLRequest.
        // Это дублирование намеренное: URLRequest.timeoutInterval — первый рубеж защиты,
        // URLSessionConfiguration.timeoutIntervalForRequest — второй. Оба должны совпадать.
        request.timeoutInterval = AppConfig.shared.requestTimeoutSeconds

        // Сериализуем тело запроса.
        // Ошибка на этом этапе означает баг в коде (неверная модель), а не сетевую проблему.
        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
        } catch {
            throw ChappieError.parsingError("Не удалось сериализовать тело запроса: \(error.localizedDescription)")
        }

        // Выполняем сетевой запрос через нашу кастомную сессию с увеличенными таймаутами.
        // Именно здесь раньше возникал таймаут при сложных задачах — теперь у нас 300 секунд.
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            // Определяем тип ошибки для более информативного сообщения пользователю.
            // NSURLErrorTimedOut — явный таймаут, даём конкретный совет.
            let nsError = error as NSError
            if nsError.code == NSURLErrorTimedOut {
                throw ChappieError.networkError(
                    "Превышено время ожидания ответа (\(Int(AppConfig.shared.requestTimeoutSeconds)) сек). " +
                    "Задача слишком сложная или сервер перегружен. Попробуй разбить задачу на части."
                )
            }
            throw ChappieError.networkError("Ошибка при выполнении запроса: \(error.localizedDescription)")
        }

        // Проверяем HTTP-статус ответа.
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChappieError.networkError("Получен некорректный тип ответа от сервера (не HTTPURLResponse)")
        }

        // Обрабатываем ошибочные HTTP-статусы.
        if !(200...299).contains(httpResponse.statusCode) {
            let errorBody = String(data: data, encoding: .utf8) ?? "Тело ответа недоступно"

            // Специальная обработка превышения лимита контекста.
            // Провайдеры могут возвращать 400 или 413 с разными сообщениями об ошибке.
            // Мы проверяем ключевые слова, чтобы дать пользователю понятный совет.
            let isContextError = httpResponse.statusCode == 413
                || errorBody.lowercased().contains("context")
                || errorBody.lowercased().contains("limit")
                || errorBody.lowercased().contains("too long")
            if isContextError {
                throw ChappieError.aiContextLimitExceeded
            }

            throw ChappieError.networkError("HTTP \(httpResponse.statusCode): \(errorBody)")
        }

        // Декодируем ответ модели.
        let result: AITunnelResponse
        do {
            result = try JSONDecoder().decode(AITunnelResponse.self, from: data)
        } catch {
            throw ChappieError.parsingError("Не удалось декодировать ответ от модели: \(error.localizedDescription)")
        }

        // Извлекаем первый (и обычно единственный) выбор из ответа.
        // Пустой массив choices — аномальная ситуация, означающая баг на стороне провайдера.
        guard let choice = result.choices.first else {
            throw ChappieError.parsingError("Модель вернула пустой массив choices — ответ отсутствует")
        }

        return (choice.message, result.usage?.cost_rub, result.usage?.balance)
    }
}
