//
//  AIOrchestrator.swift
//  ChappieCore
//
//  Created by Chappie.
//

import Foundation

/// Результат одного цикла работы оркестратора
public struct AIOrchestratorResult: Sendable {
    public let finalResponse: String
    public let totalCost: Double
    public let newBalance: Double?
    public let updatedHistory: [AIMessage]
}

/// Оркестратор ИИ-агента.
/// Что это: Управляет циклом общения с нейросетью, вызывает инструменты и поддерживает контекст.
/// Зачем: Разгружает UI (ViewModel) от сложной бизнес-логики и циклов.
public actor AIOrchestrator {
    private let aiClient: AITunnelClient
    private let toolService: ToolExecutionService
    private let fileSystem: FileSystemManager
    
    public init(aiClient: AITunnelClient, toolService: ToolExecutionService, fileSystem: FileSystemManager) {
        self.aiClient = aiClient
        self.toolService = toolService
        self.fileSystem = fileSystem
    }
    
    /// Запускает процесс обработки пользовательского запроса
    /// - Parameters:
    ///   - prompt: Текст запроса от пользователя
    ///   - history: Сетевая история сообщений
    ///   - onToolCall: Коллбэк для информирования UI о том, какой инструмент сейчас выполняется
    /// - Returns: Финальный результат (текст, стоимость, баланс, обновленная история)
    public func process(
        prompt: String,
        history: [AIMessage],
        onToolCall: @Sendable (String, String) -> Void
    ) async throws -> AIOrchestratorResult {
        var networkHistory = history
        networkHistory.append(AIMessage(role: "user", content: prompt))
        
        var totalCost: Double = 0.0
        var currentBalance: Double? = nil
        
        // Запускаем цикл общения с интеллектом (ограничение берем из AppConfig)
        let maxSteps = AppConfig.shared.maxOrchestratorSteps
        
        for _ in 0..<maxSteps {
            let fileTree = try await fileSystem.listFiles()
            
            let systemPrompt = """
            Ты — Чаппи, Senior macOS/iOS ИИ-разработчик. 
            Текущая структура файлов проекта:
            \(fileTree.joined(separator: "\n"))

            ТВОИ ПРАВИЛА:
            1. При использовании инструмента `write_file`, ВСЕГДА передавай полный, рабочий и компилируемый Swift-код.
            2. Никогда не обрывай код и не оставляй незаконченных строк.
            3. Внимательно экранируй спецсимволы в JSON.
            4. Перед сохранением убедись, что не сломал синтаксис.
            5. Для чтения или перезаписи файлов всегда ИСПОЛЬЗУЙ ИНСТРУМЕНТЫ (tools).
            """
            
            let tools = toolService.availableTools
            let (apiMessage, stepCost, stepBalance) = try await aiClient.sendRequest(
                systemPrompt: systemPrompt,
                chatHistory: networkHistory,
                tools: tools
            )
            
            if let sc = stepCost { totalCost += sc }
            if let sb = stepBalance { currentBalance = sb }
            
            networkHistory.append(apiMessage)
            
            if let toolCalls = apiMessage.tool_calls, !toolCalls.isEmpty {
                for call in toolCalls {
                    let argsDict = try? JSONSerialization.jsonObject(with: call.function.arguments.data(using: .utf8) ?? Data()) as? [String: String]
                    let targetPath = argsDict?["path"] ?? argsDict?["key"] ?? argsDict?["type"] ?? ""
                    
                    onToolCall(call.function.name, targetPath)
                    
                    let toolResult = await toolService.execute(call: call)
                    networkHistory.append(AIMessage(role: "tool", content: toolResult, tool_call_id: call.id, name: call.function.name))
                }
                continue
            } else if let content = apiMessage.content {
                return AIOrchestratorResult(
                    finalResponse: content,
                    totalCost: totalCost,
                    newBalance: currentBalance,
                    updatedHistory: networkHistory
                )
            }
        }
        
        throw ChappieError.aiContextLimitExceeded
    }
}
