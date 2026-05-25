// AIOrchestrator.swift
// ChappieCore
//
// Главный управляющий компонент — оркестратор агентного цикла Чаппи.
//
// КЛЮЧЕВЫЕ АРХИТЕКТУРНЫЕ РЕШЕНИЯ:
//
// 1. МОНОФИЗИТНАЯ АРХИТЕКТУРА:
//    Чаппи работает один, без саб-агентов и делегирования. Вся ответственность
//    за код, архитектуру, верстку и рефакторинг лежит на одном агенте.
//    Причина: саб-агенты порождают хаос, несогласованность и дублирование контекста.
//
// 2. ЕДИНЫЙ СТРИМИНГОВЫЙ ЦИКЛ (ИСПРАВЛЕНИЕ ДВОЙНОГО ЗАПРОСА):
//    Старая стратегия "probe + stream" делала ДВА запроса для каждого финального ответа.
//    НОВАЯ СТРАТЕГИЯ: streamRequestWithTools() на каждый шаг цикла.
//    AITunnelClient накапливает tool_calls из SSE-дельт и возвращает AIStreamResult.
//    Если есть tool_calls → выполняем инструменты, продолжаем цикл.
//    Если tool_calls нет → это финальный ответ. ОДИН запрос на шаг.
//
// 3. PROMPT CACHING:
//    AITunnelClient автоматически добавляет cache_control к системному промпту
//    и последнему сообщению пользователя. Экономия: ~80-90% стоимости системного промпта.
//
// 4. SELF-SUMMARY:
//    Системный промпт содержит жёсткое правило: в конце каждого финального ответа
//    Чаппи ОБЯЗАН добавлять тег <summary>...</summary>.
//    При сборке контекстного окна длинные ответы заменяются на их summary.
//
// 5. УМНОЕ КОНТЕКСТНОЕ ОКНО (оптимизация стоимости):
//    Два уровня ограничений работают одновременно:
//    а) maxMessagesInContext (12) — жёсткий лимит по количеству сообщений.
//    б) tokenBudget (6,000) — мягкий лимит по объёму токенов.
//    Последние recentFullMessages (3) всегда отправляются полностью.
//    Более старые — заменяются на summary если доступен.
//
// 6. ИСПРАВЛЕНИЕ ЗАДВОЕНИЯ ПОСЛЕДНЕГО СООБЩЕНИЯ (баг):
//    buildContextWindow() принимает ИСТОРИЮ (без текущего запроса) и ОТДЕЛЬНО currentPrompt.
//    История содержит завершённые пары user/assistant. currentPrompt — новое сообщение.
//    ВАЖНО: история, переданная в buildContextWindow(), НЕ должна содержать текущий запрос.
//    Это обеспечивается в process(): мы передаём history (прошлые сообщения) и prompt (новый).
//    Задвоение возникало, когда последнее сообщение в history == prompt. Теперь исключаем
//    дубликаты: если последнее сообщение в истории совпадает с currentPrompt по тексту,
//    оно НЕ включается в контекстное окно.
//
// 7. ОЦЕНКА ТОКЕНОВ:
//    Формула estimateTokens() использует UTF-8 байты / 4 × 1.5.
//    Это даёт реалистичную оценку для смешанного русско-английского текста с кодом.
//
// 8. ОБЯЗАТЕЛЬНЫЙ ПАЙПЛАЙН ИЗМЕНЕНИЙ (железное правило):
//    Перед каждым изменением кода Чаппи ОБЯЗАН соблюдать строгий порядок:
//    1. git_status — проверить незакоммиченные изменения от прошлой сессии.
//    2. git_add + git_commit — CHECKPOINT коммит (точка отката).
//    3. write_file — внести изменения в код.
//    4. build_project — компиляция. Если упала — ЧИНИТЬ, не идти дальше.
//    5. run_tests — тесты ТОЛЬКО если сборка прошла. Если упали — ЧИНИТЬ, не идти дальше.
//    6. git_add + git_commit — RESULT коммит только если всё зелёное.
//    7. Сообщить пользователю что можно жать треугольник в Xcode.
//    ОТКАТ: если build/tests упали и быстро не чинится — предложить git reset --hard к checkpoint.
//    ЗАПРЕЩЕНО: git_diff (загружает весь проект в контекст, стоит сотни рублей).
//    ЗАПРЕЩЕНО: run_tests до build_project (двойная компиляция).
//    ЗАПРЕЩЕНО: финальный коммит если тесты или сборка не зелёные.

import Foundation

/// Результат работы оркестратора за одну сессию.
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
/// Реализует агентный цикл (agentic loop): итеративный процесс
/// "запрос → вызов инструмента → ответ → следующий запрос",
/// который продолжается до тех пор, пока модель не вернёт финальный
/// текстовый ответ без вызовов инструментов.
public actor AIOrchestrator {
    private let aiClient: AITunnelClient
    private let toolService: ToolExecutionService
    private let fileSystem: FileSystemManager
    private let config: AppConfig

    // MARK: - Системный промпт

    /// Системный промпт — главная инструкция для модели.
    ///
    /// АРХИТЕКТУРНОЕ РЕШЕНИЕ: Все критически важные правила захардкожены здесь,
    /// а не передаются извне. Причина: эти правила — инфраструктурные гарантии системы.
    /// Память (semantic.json) может не загрузиться, история чата сжимается —
    /// только хардкод в системном промпте является 100% надёжной гарантией.
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
       Б) Локальная память таргета: файл architecture.md в корне каждого таргета. Обязательно читай architecture.md нужного таргета перед сложными задачами.
       Пути к architecture.md: Chappie/architecture.md, ChappieCore/architecture.md, ChappieMCP/architecture.md, ChappieCoreTests/architecture.md, architecture.md (корень проекта).

    5. ОБЯЗАТЕЛЬНЫЙ SELF-SUMMARY (КРИТИЧЕСКИ ВАЖНО — НИКОГДА НЕ НАРУШАТЬ):
       В самом конце КАЖДОГО своего финального ответа пользователю ты ОБЯЗАН добавить тег:
       <summary>Краткое резюме: что сделал, какие файлы изменил, какие решения принял. Максимум 2-3 предложения, только факты.</summary>
       ПРАВИЛА:
       - Тег всегда последний в ответе, после всего остального текста.
       - Внутри тега — только суть, без приветствий и лирики.
       - Если ответ короткий (приветствие, уточняющий вопрос) — summary всё равно обязателен.
       - Никогда не объясняй пользователю что такое этот тег — он его не видит.
       - Нарушение этого правила разрушает систему экономии токенов. Это недопустимо.

    6. ОБЯЗАТЕЛЬНАЯ ЗАПИСЬ АРХИТЕКТУРНЫХ РЕШЕНИЙ В ФАЙЛ (КРИТИЧЕСКИ ВАЖНО):
       Когда в разговоре принимается ЛЮБОЕ ключевое архитектурное решение, обсуждается
       важный нюанс или деталь реализации — ты ОБЯЗАН немедленно зафиксировать это
       в файле architecture.md соответствующего таргета через инструмент write_file.
       ПОЧЕМУ ЭТО КРИТИЧНО:
       - История чата агрессивно сжимается (бюджет 12,000 токенов).
       - Детали обсуждений теряются при суммаризации.
       - Файлы — единственная надёжная долгосрочная память системы.
       - Без этого правила важные решения будут утеряны навсегда.
       ЧТО ЗАПИСЫВАТЬ: архитектурные паттерны, причины выбора подхода, отклонённые альтернативы,
       важные ограничения, нюансы реализации, договорённости с пользователем.

    7. ОБЯЗАТЕЛЬНЫЙ ПАЙПЛАЙН ПЕРЕД КАЖДЫМ ИЗМЕНЕНИЕМ КОДА (ЖЕЛЕЗНОЕ ПРАВИЛО):
       Каждый раз когда нужно изменить код — СТРОГО соблюдать этот порядок:

       ШАГ 1: git_status — проверить нет ли незакоммиченных изменений от прошлой сессии.
               Если есть — разобраться с ними ПРЕЖДЕ чем начинать новое изменение.
       ШАГ 2: git_add + git_commit — сделать CHECKPOINT коммит (точка отката).
               Сообщение коммита: "checkpoint: до [описание изменения]"
       ШАГ 3: write_file — внести изменения в код.
       ШАГ 4: build_project — компиляция. Если упала — ЧИНИТЬ, не идти дальше.
       ШАГ 5: run_tests — тесты ТОЛЬКО если сборка прошла успешно.
               Если упали — ЧИНИТЬ, не идти дальше.
       ШАГ 6: git_add + git_commit — RESULT коммит ТОЛЬКО если всё зелёное.
               Сообщение коммита: "feat/fix: [описание что сделано]"
       ШАГ 7: Сообщить пользователю что можно жать треугольник в Xcode для перезапуска.

       ОТКАТ: Если build или tests упали и починить быстро не получается —
              сообщить пользователю и предложить откат: git reset --hard к checkpoint коммиту.

       ЖЕЛЕЗНЫЕ ЗАПРЕТЫ (нарушение недопустимо):
       🚫 git_diff — ЗАПРЕЩЁН НАВСЕГДА. Загружает весь проект в контекст ИИ, стоит сотни рублей.
       🚫 run_tests до build_project — тесты сами компилируют, получается двойная компиляция.
       🚫 Финальный RESULT коммит если тесты или сборка не зелёные.
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
        self.config = config
    }

    // MARK: - Публичный API

    /// Запускает агентный цикл для обработки пользовательского запроса.
    ///
    /// - Parameters:
    ///   - prompt: Текст текущего сообщения пользователя (НОВОЕ сообщение, не из истории).
    ///   - history: Полная история ЗАВЕРШЁННЫХ сообщений (без текущего prompt!).
    ///     Перед отправкой автоматически сжимается через buildContextWindow().
    ///   - onToolCall: Вызывается при каждом вызове инструмента — обновляет UI.
    ///   - onToken: Вызывается для каждого нового токена финального ответа.
    ///
    /// ВАЖНО О ДУБЛИРОВАНИИ:
    /// history должна содержать только завершённые пары user/assistant.
    /// prompt — это НОВЫЙ запрос, он добавляется в конец контекстного окна отдельно.
    /// Если вызывающий код случайно включил prompt в history — мы защищаемся от этого
    /// в buildContextWindow() проверкой на дубликат последнего сообщения.
    ///
    /// - Returns: Результат сессии: финальный ответ (с тегом <summary>), стоимость и баланс.
    /// - Throws: `ChappieError.unknown` если превышен лимит шагов из AppConfig.
    public func process(
        prompt: String,
        history: [AIMessage],
        onToolCall: @escaping @Sendable (String, String) -> Void,
        onToken: (@Sendable (String) -> Void)? = nil
    ) async throws -> AIOrchestratorResult {

        // Собираем контекстное окно: два уровня фильтрации (количество + токены),
        // добавляем текущий запрос пользователя в конец.
        // history здесь — это ПРОШЛЫЕ сообщения, prompt — НОВОЕ сообщение.
        var sessionHistory = buildContextWindow(from: history, currentPrompt: prompt)

        var totalCost: Double = 0.0
        var latestBalance: Double? = nil
        var stepCount = 0
        var executedToolSignatures = Set<String>()
        let maxSteps = config.maxOrchestratorSteps

        // MARK: - Агентный цикл

        while stepCount < maxSteps {
            stepCount += 1

            let tools = await toolService.availableTools

            // ЕДИНЫЙ СТРИМИНГОВЫЙ ЗАПРОС:
            // streamRequestWithTools() делает ОДИН запрос и возвращает AIStreamResult с:
            //   - text: накопленный текстовый ответ
            //   - toolCalls: собранные из SSE-дельт вызовы инструментов
            //   - cost/balance: финансовая статистика
            //
            // Текстовые токены уже переданы в UI через onToken во время стриминга.
            // Нам остаётся только решить: есть tool_calls → продолжаем цикл, нет → финал.
            let streamResult = try await aiClient.streamRequestWithTools(
                systemPrompt: systemPrompt,
                chatHistory: sessionHistory,
                tools: tools,
                onToken: onToken
            )

            if let cost = streamResult.cost { totalCost += cost }
            if let balance = streamResult.balance { latestBalance = balance }

            // Добавляем ответ модели в историю сессии.
            // Если были tool_calls — создаём сообщение с ними для корректной истории API.
            let assistantMessage = AIMessage(
                role: "assistant",
                content: streamResult.text.isEmpty ? nil : streamResult.text,
                toolCalls: streamResult.toolCalls
            )
            sessionHistory.append(assistantMessage)

            if let toolCalls = streamResult.toolCalls, !toolCalls.isEmpty {
                // Промежуточный шаг — выполняем инструменты и продолжаем цикл
                try await executeToolCalls(
                    toolCalls,
                    sessionHistory: &sessionHistory,
                    executedToolSignatures: &executedToolSignatures,
                    onToolCall: onToolCall
                )
                continue

            } else {
                // Финальный ответ — токены уже ушли в UI через onToken.
                // Возвращаем накопленный текст как результат сессии.
                let finalResponse = streamResult.text.isEmpty
                    ? "Нет ответа от модели."
                    : streamResult.text

                return AIOrchestratorResult(
                    finalResponse: finalResponse,
                    totalCost: totalCost > 0 ? totalCost : nil,
                    newBalance: latestBalance
                )
            }
        }

        throw ChappieError.unknown(
            "Превышен лимит шагов оркестратора (maxOrchestratorSteps = \(maxSteps)). " +
            "Цикл искусственно прерван. Увеличь AppConfig.maxOrchestratorSteps если нужно."
        )
    }

    // MARK: - Умное контекстное окно

    /// Собирает оптимальное контекстное окно из полной истории чата.
    ///
    /// ИСПРАВЛЕНИЕ БАГА ЗАДВОЕНИЯ:
    /// Ранее последнее сообщение в history (user) и currentPrompt были одним и тем же,
    /// что приводило к отправке двух одинаковых user-сообщений подряд.
    ///
    /// ПРИЧИНА БАГА: ChatHistoryManager.loadHistory() возвращает ВСЕ сообщения включая текущий запрос.
    /// При вызове process(prompt:history:) история уже содержала prompt как последний элемент.
    ///
    /// ИСПРАВЛЕНИЕ: Перед сборкой окна проверяем, не является ли последнее сообщение
    /// в истории дубликатом currentPrompt. Если да — исключаем его из истории.
    /// Это безопасная защита: даже если вызывающий код правильно передаёт историю
    /// без текущего запроса, проверка просто не срабатывает.
    ///
    /// ДВА УРОВНЯ ОГРАНИЧЕНИЙ (работают последовательно):
    ///
    /// 1. maxMessagesInContext — жёсткий лимит по количеству сообщений.
    ///    Применяется ПЕРВЫМ. Отбрасывает всё что старше последних N сообщений.
    ///
    /// 2. tokenBudget — мягкий лимит по объёму токенов.
    ///    Применяется ВТОРЫМ. Обрезает длинные сообщения если даже N штук не влезают.
    ///
    /// АЛГОРИТМ:
    /// 1. Дедупликация: убираем последнее сообщение если оно == currentPrompt.
    /// 2. Берём последние maxMessagesInContext сообщений.
    /// 3. Последние recentFullMessages — полностью (текущий контекст задачи).
    /// 4. Более старые — сжимаем через summary если доступен.
    /// 5. Идём назад пока не исчерпан tokenBudget.
    /// 6. Добавляем currentPrompt как последнее сообщение.
    private func buildContextWindow(from history: [AIMessage], currentPrompt: String) -> [AIMessage] {
        let budget = config.tokenBudget
        let recentCount = config.recentFullMessages
        let summaryThreshold = config.summaryThreshold
        let maxMessages = config.maxMessagesInContext

        // Диагностика ПЕРЕД сжатием
        let totalTokensBefore = history.reduce(0) { $0 + estimateTokens($1) }
        print("[AIOrchestrator] 📥 История: \(history.count) сообщений, ~\(totalTokensBefore) токенов | Бюджет: \(budget), лимит: \(maxMessages) сообщений")

        // ШАГ 1: ДЕДУПЛИКАЦИЯ — убираем последнее сообщение если оно совпадает с currentPrompt.
        //
        // ПОЧЕМУ ЭТО ПРОИСХОДИТ:
        // ChatHistoryManager.loadHistory() возвращает ВСЕ сообщения включая только что
        // отправленный пользователем запрос. Этот же запрос передаётся как prompt.
        // Результат: history.last.content == currentPrompt → задвоение.
        //
        // РЕШЕНИЕ: Проверяем последнее user-сообщение в истории. Если его текст совпадает
        // с currentPrompt — отбрасываем его. currentPrompt добавится в конце отдельно.
        let deduplicatedHistory: [AIMessage]
        if let lastMessage = history.last,
           lastMessage.role == "user",
           lastMessage.contentString == currentPrompt {
            // Последнее сообщение — дубликат текущего запроса. Убираем его.
            deduplicatedHistory = Array(history.dropLast())
            print("[AIOrchestrator] 🔧 Дедупликация: убрано задвоенное последнее сообщение")
        } else {
            deduplicatedHistory = history
        }

        // ШАГ 2: Жёсткий лимит по количеству
        let cappedHistory = deduplicatedHistory.count > maxMessages
            ? Array(deduplicatedHistory.suffix(maxMessages))
            : deduplicatedHistory

        // ШАГ 3: Разбиваем на "свежую" и "старую" зоны
        let recentMessages: [AIMessage]
        let olderMessages: [AIMessage]

        if cappedHistory.count <= recentCount {
            recentMessages = cappedHistory
            olderMessages = []
        } else {
            recentMessages = Array(cappedHistory.suffix(recentCount))
            olderMessages = Array(cappedHistory.prefix(cappedHistory.count - recentCount))
        }

        // Свежие сообщения всегда включаются — считаем их токены как базовую нагрузку
        var usedTokens = recentMessages.reduce(0) { $0 + estimateTokens($1) }

        // ШАГ 4: Идём по старым сообщениям с конца (ближайшие — важнее)
        var selectedOlder: [AIMessage] = []
        for message in olderMessages.reversed() {
            let compressed = compressMessage(message, summaryThreshold: summaryThreshold)
            let tokens = estimateTokens(compressed)

            if usedTokens + tokens <= budget {
                selectedOlder.insert(compressed, at: 0)
                usedTokens += tokens
            } else {
                // Токенный бюджет исчерпан — отбрасываем остаток.
                // СОЗНАТЕЛЬНОЕ РЕШЕНИЕ: лучше потерять давнюю историю, чем свежий контекст.
                break
            }
        }

        // Собираем финальное окно: старые (сжатые) + свежие (полные) + текущий запрос
        var contextWindow = selectedOlder + recentMessages
        contextWindow.append(AIMessage(role: "user", content: currentPrompt))

        // Диагностика ПОСЛЕ сжатия
        let totalTokensAfter = contextWindow.reduce(0) { $0 + estimateTokens($1) }
        print("[AIOrchestrator] 📤 Отправляю: \(contextWindow.count) сообщений, ~\(totalTokensAfter) токенов (сжато с \(totalTokensBefore) → \(totalTokensAfter))")

        return contextWindow
    }

    /// Сжимает сообщение до его summary если оно достаточно длинное.
    private func compressMessage(_ message: AIMessage, summaryThreshold: Int) -> AIMessage {
        guard let fullText = message.contentString,
              estimateTokens(message) > summaryThreshold,
              let summary = extractSummary(from: fullText) else {
            return message
        }

        return AIMessage(
            role: message.role,
            content: "[СЖАТО] \(summary)",
            tool_call_id: message.tool_call_id,
            name: message.name
        )
    }

    /// Извлекает текст из тега <summary>...</summary>.
    private func extractSummary(from text: String) -> String? {
        let openTag = "<summary>"
        let closeTag = "</summary>"

        guard let openRange = text.range(of: openTag),
              let closeRange = text.range(of: closeTag),
              openRange.upperBound < closeRange.lowerBound else {
            return nil
        }

        let summary = String(text[openRange.upperBound..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return summary.isEmpty ? nil : summary
    }

    /// Оценивает количество токенов в сообщении.
    ///
    /// ФОРМУЛА: UTF-8 байты / 4 × 1.5
    /// Корректно работает для смешанного русско-английского текста с кодом.
    private func estimateTokens(_ message: AIMessage) -> Int {
        let text = message.contentString ?? ""
        let utf8ByteCount = text.utf8.count
        let estimated = Int(Double(utf8ByteCount) / 4.0 * 1.5)
        return max(1, estimated)
    }

    // MARK: - Приватные методы агентного цикла

    /// Выполняет список tool_calls: проверяет на повторы, уведомляет UI, запускает сервис.
    private func executeToolCalls(
        _ toolCalls: [AIToolCall],
        sessionHistory: inout [AIMessage],
        executedToolSignatures: inout Set<String>,
        onToolCall: @Sendable (String, String) -> Void
    ) async throws {
        for toolCall in toolCalls {
            let toolName = toolCall.function.name
            let arguments = toolCall.function.arguments
            let targetPath = extractTargetPath(from: arguments)
            let signature = "\(toolName)|\(arguments)"
            let resultString: String

            if executedToolSignatures.contains(signature) {
                // Защита от зацикливания: модель пытается повторить уже выполненный вызов
                resultString = """
                СИСТЕМНАЯ ОШИБКА: Ты уже вызывал инструмент `\(toolName)` с точно такими же аргументами в этой сессии.
                ЗАПРЕЩЕНО ПОВТОРЯТЬ ОДНО И ТО ЖЕ ДЕЙСТВИЕ. ИСПОЛЬЗУЙ ДРУГОЙ ПОДХОД.
                """
            } else {
                executedToolSignatures.insert(signature)
                onToolCall(toolName, targetPath)
                resultString = await toolService.execute(call: toolCall)
            }

            let toolResponse = AIMessage(
                role: "tool",
                content: resultString,
                tool_call_id: toolCall.id,
                name: toolName
            )
            sessionHistory.append(toolResponse)
        }
    }

    /// Извлекает путь к файлу из JSON-аргументов для красивого отображения в UI.
    private func extractTargetPath(from arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        return json["path"] as? String ?? ""
    }
}
