// AIOrchestrator.swift
// ChappieCore
//
// Главный управляющий компонент — оркестратор агентного цикла Чаппи.

import Foundation

/// Результат работы оркестратора за одну сессию.
///
/// Зачем выносить в отдельную структуру: помимо финального текста ответа,
/// нам важно знать стоимость запроса и текущий баланс — это выводится
/// в UI и помогает контролировать расходы.
public struct AIOrchestratorResult: Sendable {
    public let finalResponse: String
    public let totalCost: Double?
    public let newBalance: Double?

    public init(finalResponse: String, totalCost: Double?, newBalance: Double?) {
        self.finalResponse = finalResponse
        self.totalCost = totalCost
        self.newBalance = newBalance
    }
}

/// Оркестратор ИИ-агента — главный управляющий компонент ChappieCore.
///
/// Что это: Актор, реализующий агентный цикл (agentic loop) — итеративный
/// процесс "запрос → вызов инструмента → ответ → следующий запрос",
/// который продолжается до тех пор, пока модель не вернёт финальный текст
/// без вызовов инструментов.
///
/// Зачем актор: Оркестратор управляет изменяемым состоянием сессии
/// (история сообщений, счётчик шагов) и вызывается из разных контекстов.
/// Актор гарантирует безопасный доступ без гонок данных (Swift 6).
///
/// Архитектурное решение — монофизит: Чаппи работает один, без саб-агентов.
/// `ToolExecutionService` предоставляет все инструменты напрямую.
public actor AIOrchestrator {
    private let aiClient: AITunnelClient
    private let toolService: ToolExecutionService
    private let fileSystem: FileSystemManager

    /// Конфигурация приложения — единственный источник истины для всех лимитов.
    ///
    /// Зачем хранить ссылку: Чтобы не обращаться к `AppConfig.shared` в каждой
    /// итерации цикла. Конфигурация неизменяема (struct), поэтому копирование
    /// при инициализации безопасно и эффективно.
    private let config: AppConfig

    /// Системный промпт, который формирует личность и правила поведения Чаппи.
    ///
    /// Зачем выносить в константу: Промпт передаётся в каждый API-запрос
    /// в рамках сессии. Хранение в одном месте упрощает редактирование
    /// и исключает дублирование.
    private let systemPrompt = """
    Ты — Чаппи, гениальный Senior macOS/iOS ИИ-разработчик.
    Проект написан на Swift 6 с полным контролем конкурентности, SwiftUI, и таргетом macOS 26+.
    Ты являешься единым, всемогущим Ядром системы на базе первоклассной модели Claude Sonnet 4.6.
    У тебя нет команды, ты делаешь всё сам от начала до конца: от архитектуры до верстки и финального рефакторинга.

    ТВОИ НЕОТСТУПНЫЕ ПРАВИЛА:

    1. АБСОЛЮТНАЯ САМОСТОЯТЕЛЬНОСТЬ:
       Вся ответственность за проект лежит на тебе. Используй инструменты напрямую, чтобы читать, анализировать и переписывать файлы. Твои решения окончательные.

    2. ПРИНЦИП ОТЧУЖДАЕМОСТИ КОДА:
       Весь код, который ты создаешь, ОБЯЗАН быть плотно обложен понятными и подробными комментариями на идеальном русском языке.
       Комментарии должны объяснять ПОЧЕМУ написан этот код, а не только ЧТО он делает.

    3. СИНТАКСИС И КОМПИЛЯЦИЯ:
       Перед сохранением кода всегда проверяй синтаксис Swift 6. Код должен быть полностью компилируемым и готовым к работе. Возвращай через write_file только полные файлы, никогда не обрывай строки и не оставляй незаконченных блоков!

    4. СТРУКТУРА ПАМЯТИ:
       Ты работаешь с двумя типами памяти:
       А) Глобальная память: общие факты и кросс-проектные знания (файлы semantic.json в Documents). Инструменты: memorize, recall со scope = "global".
       Б) Локальная память таргета: файлы в папке AI_Docs конкретного таргета. Обязательно читай architecture.md и project_map.md нужного таргета перед сложными задачами.
    """

    public init(
        aiClient: AITunnelClient,
        toolService: ToolExecutionService,
        fileSystem: FileSystemManager,
        config: AppConfig = .shared
    ) {
        self.aiClient = aiClient
        self.toolService = toolService
        self.fileSystem = fileSystem
        // Сохраняем конфиг при инициализации — он неизменяем (struct),
        // поэтому это безопасная копия всех параметров на момент создания оркестратора.
        self.config = config
    }

    /// Запускает агентный цикл для обработки пользовательского запроса.
    ///
    /// - Parameters:
    ///   - prompt: Текст текущего сообщения пользователя.
    ///   - history: История предыдущих сообщений в сессии (контекст разговора).
    ///   - onToolCall: Замыкание, вызываемое при каждом вызове инструмента —
    ///     используется для обновления UI (показать, что Чаппи что-то делает).
    /// - Returns: Результат сессии: финальный ответ, стоимость и баланс.
    /// - Throws: `ChappieError.unknown` если превышен лимит шагов из `AppConfig`.
    public func process(
        prompt: String,
        history: [AIMessage],
        onToolCall: @escaping @Sendable (String, String) -> Void
    ) async throws -> AIOrchestratorResult {

        // Формируем историю сессии: берём переданный контекст и добавляем
        // текущее сообщение пользователя, если оно ещё не добавлено.
        var sessionHistory = history
        if sessionHistory.isEmpty || sessionHistory.last?.content != prompt {
            sessionHistory.append(AIMessage(role: "user", content: prompt))
        }

        var totalCost: Double = 0.0
        var latestBalance: Double? = nil
        var stepCount = 0

        // Множество сигнатур уже выполненных вызовов инструментов.
        // Зачем: Защита от зацикливания — если модель пытается вызвать
        // инструмент с теми же аргументами повторно, мы перехватываем это
        // и возвращаем жёсткое предупреждение вместо реального выполнения.
        var executedToolSignatures = Set<String>()

        // Читаем лимит шагов из единственного источника истины — AppConfig.
        // Раньше здесь был захардкоженный `maxSteps = 100`, который дублировал
        // значение из AppConfig и создавал два источника истины для одного параметра.
        // Теперь изменение лимита в AppConfig автоматически применяется везде.
        let maxSteps = config.maxOrchestratorSteps

        // MARK: - Агентный цикл

        while stepCount < maxSteps {
            stepCount += 1

            // Получаем актуальный список инструментов и отправляем запрос к API
            let tools = await toolService.availableTools
            let (responseMessage, cost, balance) = try await aiClient.sendRequest(
                systemPrompt: systemPrompt,
                chatHistory: sessionHistory,
                tools: tools
            )

            if let cost = cost { totalCost += cost }
            if let balance = balance { latestBalance = balance }

            // Добавляем ответ модели в историю — это обязательно для корректного
            // контекста при следующем запросе (API требует полную цепочку)
            sessionHistory.append(responseMessage)

            // MARK: Обработка вызовов инструментов

            if let toolCalls = responseMessage.tool_calls, !toolCalls.isEmpty {

                for toolCall in toolCalls {
                    let toolName = toolCall.function.name
                    let arguments = toolCall.function.arguments
                    let targetPath = extractTargetPath(from: arguments)

                    let signature = "\(toolName)|\(arguments)"
                    let resultString: String

                    if executedToolSignatures.contains(signature) {
                        // Модель пытается повторить уже выполненное действие — это цикл.
                        // Возвращаем жёсткое предупреждение, чтобы модель сменила подход.
                        resultString = """
                        СИСТЕМНАЯ ОШИБКА: Ты уже вызывал инструмент `\(toolName)` с точно такими же аргументами в этой сессии.
                        ЗАПРЕЩЕНО ПОВТОРЯТЬ ОДНО И ТО ЖЕ ДЕЙСТВИЕ. ИСПОЛЬЗУЙ ДРУГОЙ ПОДХОД.
                        """
                    } else {
                        executedToolSignatures.insert(signature)
                        // Уведомляем UI о том, какой инструмент сейчас выполняется
                        onToolCall(toolName, targetPath)
                        resultString = await toolService.execute(call: toolCall)
                    }

                    // Добавляем результат инструмента в историю с правильной ролью "tool"
                    // и привязкой к конкретному вызову через tool_call_id
                    let toolResponse = AIMessage(
                        role: "tool",
                        content: resultString,
                        tool_call_id: toolCall.id,
                        name: toolName
                    )
                    sessionHistory.append(toolResponse)
                }

                // После выполнения инструментов возвращаемся к началу цикла,
                // чтобы отправить их результаты модели и получить следующий ответ
                continue

            } else {
                // Модель вернула текст без вызовов инструментов — это финальный ответ
                let finalResponse = responseMessage.content ?? "Нет ответа от модели."

                return AIOrchestratorResult(
                    finalResponse: finalResponse,
                    totalCost: totalCost > 0 ? totalCost : nil,
                    newBalance: latestBalance
                )
            }
        }

        // Если дошли до сюда — цикл превысил лимит шагов.
        // Сообщение содержит актуальное значение из AppConfig, а не захардкоженное число.
        throw ChappieError.unknown(
            "Превышен лимит шагов оркестратора (maxOrchestratorSteps = \(maxSteps)). " +
            "Цикл искусственно прерван. Увеличь AppConfig.maxOrchestratorSteps если нужно."
        )
    }

    /// Извлекает путь к файлу из JSON-аргументов вызова инструмента.
    ///
    /// Зачем: Используется для красивого отображения в UI — вместо
    /// "выполняется write_file" показываем "записывается ContentView.swift".
    private func extractTargetPath(from arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        return json["path"] as? String ?? ""
    }
}
