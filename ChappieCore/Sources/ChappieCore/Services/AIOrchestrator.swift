//
//  AIOrchestrator.swift
//  ChappieCore
//
//  Created by Chappie.
//

import Foundation

/// Результат работы оркестратора.
/// Содержит финальный текстовый ответ модели, общую стоимость запросов и новый баланс пользователя.
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

/// Главный оркестратор ИИ-агентов (Ядро / Архитектор).
/// Что это: Актер, реализующий многошаговый цикл рассуждений (Reasoning Loop) и вызова инструментов.
/// Зачем: Он управляет процессом решения задач пользователя, самостоятельно решая, в какой момент
/// прочитать файл, записать изменения или делегировать задачу специализированному саб-агенту.
public actor AIOrchestrator {
    private let aiClient: AITunnelClient
    private let toolService: ToolExecutionService
    private let fileSystem: FileSystemManager
    
    /// Максимальное количество шагов в рамках одного цикла рассуждений для предотвращения бесконечных циклов.
    private let maxSteps = 15
    
    /// Инициализатор оркестратора.
    /// - Parameters:
    ///   - aiClient: Клиент для сетевых запросов к основному ИИ (Gemini 3.5 Flash).
    ///   - toolService: Сервис выполнения инструментов файловой системы и делегирования.
    ///   - fileSystem: Менеджер файловой системы.
    public init(aiClient: AITunnelClient, toolService: ToolExecutionService, fileSystem: FileSystemManager) {
        self.aiClient = aiClient
        self.toolService = toolService
        self.fileSystem = fileSystem
    }
    
    /// Основной метод обработки запроса пользователя.
    /// - Parameters:
    ///   - prompt: Текст запроса от пользователя.
    ///   - history: Предыдущая история переписки, очищенная от тяжелого кода.
    ///   - onToolCall: Коллбэк, вызываемый при каждом выполнении инструмента для отображения прогресса в UI.
    /// - Returns: Структурированный результат с ответом и балансом.
    public func process(
        prompt: String,
        history: [AIMessage],
        onToolCall: @escaping @Sendable (String, String) -> Void
    ) async throws -> AIOrchestratorResult {
        
        // Базовая история сообщений для текущей сессии размышлений.
        // Она остается несжатой на протяжении всего цикла process, чтобы у ИИ была идеальная локальная память.
        var sessionHistory = history
        
        // Если история пуста или последнее сообщение не совпадает по смыслу с текущим запросом,
        // добавляем запрос пользователя в историю.
        if sessionHistory.isEmpty || sessionHistory.last?.content != prompt {
            sessionHistory.append(AIMessage(role: "user", content: prompt))
        }
        
        var totalCost: Double = 0.0
        var latestBalance: Double? = nil
        var stepCount = 0
        
        // Формируем фундаментальный системный промпт, вшивая в него наши нерушимые правила.
        let systemPrompt = """
        Ты — Чаппи, Senior macOS/iOS ИИ-разработчик. 
        Проект написан на Swift 6 с полным контролем конкурентности, SwiftUI, и таргетом macOS 26+.
        Ты являешься Ядром (Архитектором) всей системы и работаешь на базе мощной модели Gemini 3.5 Flash.
        
        ТВОИ НЕОТСТУПНЫЕ ПРАВИЛА:
        
        1. СТРУКТУРА НАШЕЙ DREAM TEAM:
           У тебя есть виртуальная команда разработчиков разного уровня. Ты можешь делегировать им задачи с помощью инструмента `delegate_task`:
           - Сеньор ("senior"): Claude Sonnet 4.6. Лучший в сложной архитектуре, Swift 6 Concurrency, устранении хитрых багов и проектировании API.
           - Мидл ("middle"): GPT 5.4 Mini. Идеально подходит для верстки экранов на SwiftUI, CRUD-операций, написания стандартных сервисов и сетевых слоев.
           - Джун ("junior"): Gemini 3.1 Flash Lite. Отличен для рутинной работы: рефакторинга имен, добавления комментариев, форматирования кода.
           
        2. СТРОГО ПОСЛЕДОВАТЕЛЬНАЯ РАБОТА:
           Ни в коем случае не запускай саб-агентов параллельно! Только последовательное выполнение. 
           Дождись завершения работы одного саб-агента, получи его код, примени его к проекту с помощью инструмента `write_file`, и только после этого запускай следующего саб-агента, если требуется. Пересечение работы агентов недопустимо!
           
        3. ПРИНЦИП ОТЧУЖДАЕМОСТИ КОДА:
           Весь код, который создаешь ты или твои саб-агенты, ОБЯЗАН быть плотно обложен понятными и подробными комментариями на хорошем, грамотном русском языке.
           Комментарии должны объяснять ПОЧЕМУ написан этот код, а не только ЧТО он делает. Любой сторонний разработчик должен открыть код и мгновенно во всём разобраться без твоего участия.
           
        4. ИЗОЛЯЦИЯ ИНСТРУМЕНТОВ:
           Только ты (Ядро) имеешь доступ к инструментам прямого изменения файлов (`write_file`, `delete_file`), чтению (`read_file`, `list_files`) и памяти. Саб-агенты — это изолированные функции, они получают только тот контекст, который ты им передаешь, и возвращают готовый код.
           
        5. СИНТАКСИС И КОМПИЛЯЦИЯ:
           Перед сохранением кода всегда проверяй синтаксис Swift 6. Код должен быть полностью компилируемым и готовым к работе. Никогда не обрывай строки и не оставляй незаконченных блоков.

        6. СТРУКТУРА ПАМЯТИ И ДЕЦЕНТРАЛИЗАЦИЯ:
           У нас есть строгая и детерминированная структура памяти, которая инициализируется приложением автоматически при выборе папки. Ты должен прекрасно знать её устройство и правильно использовать инструменты памяти:
           
           А) Постоянная (глобальная) память Чаппи:
              - Находится в папке Chappie в документах пользователя по пути: `~/Documents/Chappie/semantic.json`.
              - Хранит твои кросс-проектные знания, твои правила, особенности твоей Dream Team (кто у нас Senior, Middle, Junior), глобальные настройки и другие долгосрочные факты.
              - Для работы с ней используй инструменты `memorize`, `recall`, `search_memory`, `delete_memory` со scope = "global" (или без указания targetName при вызове инструментов).
              
           Б) Файлы памяти о проекте (над которым сейчас ведется работа):
              - Находятся СТРОГО внутри папки конкретного таргета проекта (например, `Chappie/AI_Docs/` для основного приложения).
              - В корне проекта никаких файлов памяти нет и быть не должно! Из Xcode-проекта корень не виден, поэтому все файлы лежат в таргетах.
              - В папке `<TargetName>/AI_Docs/` находятся:
                1. `semantic.json` — общая семантика проекта. Для работы с ней используй инструменты памяти с параметром targetName (например, `"targetName": "Chappie"`).
                2. `architecture.md` — файл с описанием текущей архитектуры на языке Mermaid. Обновляй его вручную через `write_file` при крупных архитектурных изменениях.
                3. `project_map.md` — файл с описанием структуры проекта (где какие папки и файлы и зачем они нужны). Он автоматически генерируется приложением, но ты можешь дополнять его описание.
                
           В) Файлы памяти о подключенных библиотеках (над которыми сейчас ведется работа):
              - Находятся СТРОГО внутри папки конкретного библиотечного таргета/пакета (например, `ChappieCore/AI_Docs/`).
              - В папке `<LibraryTargetName>/AI_Docs/` находятся:
                1. `semantic.json` — общая семантика библиотеки. Работай с ней через инструменты памяти с параметром targetName (например, `"targetName": "ChappieCore"`).
                2. `architecture.md` — архитектура библиотеки на языке Mermaid.
                3. `project_map.md` — структура библиотеки (где какие папки и файлы).
                
           Г) Правила работы с памятью:
              - Прежде чем выполнять сложную задачу, всегда читай `architecture.md` и `project_map.md` нужного таргета, а также делай `search_memory` или `recall` с указанием соответствующего `targetName`.
              - Когда ты узнаешь новые факты о конкретном таргете (например, новые соглашения о коде, исправленные баги, логику работы API), обязательно сохраняй их через `memorize` с указанием соответствующего `targetName`.
        """
        
        // Запускаем многошаговый цикл рассуждений (Reasoning Loop)
        while stepCount < maxSteps {
            stepCount += 1
            
            // Получаем доступные инструменты из ToolExecutionService
            let tools = await toolService.availableTools
            
            // Отправляем запрос к основному ИИ (Gemini 3.5 Flash)
            let (responseMessage, cost, balance) = try await aiClient.sendRequest(
                systemPrompt: systemPrompt,
                chatHistory: sessionHistory,
                tools: tools
            )
            
            // Накапливаем стоимость и обновляем баланс
            if let cost = cost {
                totalCost += cost
            }
            if let balance = balance {
                latestBalance = balance
            }
            
            // Добавляем ответ ассистента в историю текущей сессии
            sessionHistory.append(responseMessage)
            
            // Если модель решила вызвать инструменты
            if let toolCalls = responseMessage.tool_calls, !toolCalls.isEmpty {
                
                for toolCall in toolCalls {
                    let toolName = toolCall.function.name
                    let arguments = toolCall.function.arguments
                    let targetPath = extractTargetPath(from: arguments)
                    
                    // Оповещаем UI-слой о начале выполнения инструмента
                    onToolCall(toolName, targetPath)
                    
                    // Выполняем инструмент в ToolExecutionService
                    let resultString = await toolService.execute(call: toolCall)
                    
                    // Создаем сообщение с результатом выполнения инструмента
                    let toolResponse = AIMessage(
                        role: "tool",
                        content: resultString,
                        tool_call_id: toolCall.id,
                        name: toolName
                    )
                    
                    // Добавляем результат работы инструмента в историю сессии
                    sessionHistory.append(toolResponse)
                }
                
                // Переходим на следующий шаг цикла для обработки результатов выполнения инструментов
                continue
            } else {
                // Если инструментов для вызова нет, значит модель дала финальный текстовый ответ
                let finalResponse = responseMessage.content ?? "Нет ответа от модели."
                
                return AIOrchestratorResult(
                    finalResponse: finalResponse,
                    totalCost: totalCost > 0 ? totalCost : nil,
                    newBalance: latestBalance
                )
            }
        }
        
        // Если мы превысили максимальное количество шагов, возвращаем предупреждение
        throw ChappieError.unknown("Превышен лимит шагов оркестратора (maxSteps = \(maxSteps)). Возможно, ИИ попал в бесконечный цикл.")
    }
    
    /// Вспомогательный метод для извлечения пути к файлу из аргументов вызова функции.
    /// Это нужно, чтобы красиво отображать в UI, какой именно файл сейчас обрабатывается.
    private func extractTargetPath(from arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        return json["path"] as? String ?? ""
    }
}
