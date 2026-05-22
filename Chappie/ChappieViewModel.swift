//
//  ChappieViewModel.swift
//  Chappie
//
//  Created by  Сергей on 21.05.2026.
//

import SwiftUI
import ChappieCore

struct ChatMessage: Identifiable, Hashable, Codable {
    var id = UUID()
    let isUser: Bool
    let text: String
    var cost: Double? = nil
}

@Observable
@MainActor
final class ChappieViewModel {
    var workspaceURL: URL?
    
    var messages: [ChatMessage] = [] {
        didSet { saveMessages() }
    }
    
    var isThinking = false
    
    var currentBalance: Double? {
        didSet { UserDefaults.standard.set(currentBalance, forKey: "savedBalance") }
    }
    
    private var fileSystem: FileSystemManager?
    private var toolService: ToolExecutionService?
    private let aiClient = AITunnelClient()
    
    init() {
        loadMessages()
        if let savedBalance = UserDefaults.standard.object(forKey: "savedBalance") as? Double {
            self.currentBalance = savedBalance
        }
        loadWorkspaceWithSecurityScope()
    }
    
    func setWorkspace(_ url: URL) {
        workspaceURL = url
        fileSystem = FileSystemManager(workspaceURL: url)
        toolService = ToolExecutionService(fileSystem: fileSystem)
        saveWorkspaceWithSecurityScope(url)
        
        if messages.isEmpty {
            messages.append(ChatMessage(isUser: false, text: "Проект подключен. Я готов к работе!"))
        }
    }
    
    func send(prompt: String) {
        guard !prompt.isEmpty else { return }
        
        messages.append(ChatMessage(isUser: true, text: prompt))
        isThinking = true
        
        // Подготавливаем чистую историю (без технических приветствий и без промежуточных плашек инструментов)
        let cleanHistory: [AIMessage] = messages.compactMap { msg -> AIMessage? in
            if msg.text.contains("Проект подключен") || msg.text.hasPrefix("🛠") { return nil }
            return AIMessage(role: msg.isUser ? "user" : "assistant", content: msg.text)
        }
        
        // Ограничиваем историю последних N сообщений для экономии токенов и ускорения
        let historyLimit = 15
        var networkHistory = Array(cleanHistory.suffix(historyLimit))
        
        Task {
            var totalCost: Double = 0.0
            
            // Запускаем цикл общения с интеллектом (ограничиваем 10 шагами, чтобы не ушел в бесконечность)
            for _ in 0..<10 {
                do {
                    // 1. Формируем контекст с всегда актуальным списком файлов
                    var fileTree: [String] = []
                    if let fileSystem { fileTree = try await fileSystem.listFiles() }
                    
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
                    
                    // 2. Отправляем запрос
                    let tools = toolService?.availableTools ?? []
                    let (apiMessage, stepCost, stepBalance) = try await aiClient.sendRequest(
                        systemPrompt: systemPrompt,
                        chatHistory: networkHistory,
                        tools: tools
                    )
                    
                    if let sc = stepCost { totalCost += sc }
                    if let sb = stepBalance { self.currentBalance = sb }
                    
                    // Сохраняем ответ агента в сетевую историю
                    networkHistory.append(apiMessage)
                    
                    // 3. Проверяем: это текст или вызов функции?
                    if let toolCalls = apiMessage.tool_calls, !toolCalls.isEmpty {
                        
                        // Агент решил использовать инструменты! 
                        for call in toolCalls {
                            // Печатаем в UI красивую информационную плашку
                            let argsDict = try? JSONSerialization.jsonObject(with: call.function.arguments.data(using: .utf8) ?? Data()) as? [String: String]
                            let targetPath = argsDict?["path"] ?? argsDict?["key"] ?? argsDict?["type"] ?? ""
                            self.messages.append(ChatMessage(isUser: false, text: "🛠 Выполняю: \(call.function.name) -> \(targetPath)", cost: nil))
                            
                            // Выполняем реальный код через сервис
                            let toolResult = await toolService?.execute(call: call) ?? "Ошибка: ToolExecutionService недоступен"
                            
                            // Возвращаем результат нейросети
                            networkHistory.append(AIMessage(role: "tool", content: toolResult, tool_call_id: call.id, name: call.function.name))
                        }
                        
                        // Идем на следующий круг `for` отправлять результаты нейронке
                        continue
                        
                    } else if let content = apiMessage.content {
                        // Инструментов больше нет, есть финальный текст! Отдаем его пользователю и завершаем задачу.
                        self.messages.append(ChatMessage(isUser: false, text: content, cost: totalCost))
                        break
                    }
                    
                } catch {
                    self.messages.append(ChatMessage(isUser: false, text: "Упс, ошибка сети: \(error.localizedDescription)"))
                    break
                }
            } // конец цикла `for`
            
            isThinking = false
        }
    }
    
    // MARK: - Локальное сохранение / Восстановление
    
    private func saveMessages() {
        if let encoded = try? JSONEncoder().encode(messages) { UserDefaults.standard.set(encoded, forKey: "savedChatMessages") }
    }
    
    private func loadMessages() {
        if let data = UserDefaults.standard.data(forKey: "savedChatMessages"),
           let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) { self.messages = decoded }
    }
    
    private func saveWorkspaceWithSecurityScope(_ url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmarkData, forKey: "workspaceBookmark")
        } catch {
            if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(data, forKey: "workspaceBookmark")
            }
        }
    }
    
    private func loadWorkspaceWithSecurityScope() {
        guard let data = UserDefaults.standard.data(forKey: "workspaceBookmark") else { return }
        var isStale = false
        if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
            _ = url.startAccessingSecurityScopedResource()
            self.workspaceURL = url
            self.fileSystem = FileSystemManager(workspaceURL: url)
            self.toolService = ToolExecutionService(fileSystem: self.fileSystem)
        } else if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
            self.workspaceURL = url
            self.fileSystem = FileSystemManager(workspaceURL: url)
            self.toolService = ToolExecutionService(fileSystem: self.fileSystem)
        }
    }
}
