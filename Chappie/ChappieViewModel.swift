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
    private var aiClient: AITunnelClient
    private var orchestrator: AIOrchestrator?
    
    init() {
        // Читаем API-ключ из UserDefaults. В будущем можно добавить UI для его ввода и хранить в Keychain.
        let defaultKey = "REMOVED_API_KEY"
        let savedKey = UserDefaults.standard.string(forKey: "aiTunnelApiKey") ?? defaultKey
        self.aiClient = AITunnelClient(apiKey: savedKey)
        
        loadMessages()
        if let savedBalance = UserDefaults.standard.object(forKey: "savedBalance") as? Double {
            self.currentBalance = savedBalance
        }
        loadWorkspaceWithSecurityScope()
    }
    
    func setWorkspace(_ url: URL) {
        workspaceURL = url
        let fs = FileSystemManager(workspaceURL: url)
        self.fileSystem = fs
        
        let ts = ToolExecutionService(fileSystem: fs)
        self.toolService = ts
        
        self.orchestrator = AIOrchestrator(aiClient: aiClient, toolService: ts, fileSystem: fs)
        
        saveWorkspaceWithSecurityScope(url)
        
        if messages.isEmpty {
            messages.append(ChatMessage(isUser: false, text: "Проект подключен. Я готов к работе!"))
        }
    }
    
    func send(prompt: String) {
        guard !prompt.isEmpty else { return }
        guard let orchestrator = orchestrator else {
            messages.append(ChatMessage(isUser: false, text: "Ошибка: Оркестратор не инициализирован. Подключите папку с проектом."))
            return
        }
        
        messages.append(ChatMessage(isUser: true, text: prompt))
        isThinking = true
        
        // Подготавливаем чистую историю (без технических приветствий и без промежуточных плашек инструментов)
        let cleanHistory: [AIMessage] = messages.compactMap { msg -> AIMessage? in
            if msg.text.contains("Проект подключен") || msg.text.hasPrefix("🛠") { return nil }
            return AIMessage(role: msg.isUser ? "user" : "assistant", content: msg.text)
        }
        
        // Используем лимит из AppConfig (устранение магического числа 15)
        let historyLimit = AppConfig.shared.maxHistoryMessages
        let networkHistory = Array(cleanHistory.suffix(historyLimit))
        
        Task {
            do {
                let result = try await orchestrator.process(
                    prompt: prompt,
                    history: networkHistory,
                    onToolCall: { toolName, targetPath in
                        Task { @MainActor in
                            self.messages.append(ChatMessage(isUser: false, text: "🛠 Выполняю: \(toolName) -> \(targetPath)", cost: nil))
                        }
                    }
                )
                
                let cleanedResponse = self.cleanAIResponse(result.finalResponse)
                self.messages.append(ChatMessage(isUser: false, text: cleanedResponse, cost: result.totalCost))
                
                if let newBalance = result.newBalance {
                    self.currentBalance = newBalance
                }
            } catch {
                self.messages.append(ChatMessage(isUser: false, text: "Упс, ошибка: \(error.localizedDescription)"))
            }
            
            isThinking = false
        }
    }
    
    // MARK: - Очистка ответа от служебных мыслей
    
    private func cleanAIResponse(_ text: String) -> String {
        var cleanedText = text
        
        // Удаляем блок мыслей (от 94>thought до No more tool calls are needed. или похожего конца)
        if let regex = try? NSRegularExpression(pattern: "94>thought.*?needed\\.\\n*", options: [.dotMatchesLineSeparators]) {
            cleanedText = regex.stringByReplacingMatches(
                in: cleanedText,
                options: [],
                range: NSRange(location: 0, length: cleanedText.utf16.count),
                withTemplate: ""
            )
        }
        
        return cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Локальное сохранение / Восстановление
    
    private func saveMessages() {
        // Используем новый сервис для сохранения истории в файл (Tech Debt #2)
        ChatHistoryManager.shared.saveMessages(messages)
    }
    
    private func loadMessages() {
        // Пытаемся загрузить из нового места (файла)
        let loadedMessages: [ChatMessage] = ChatHistoryManager.shared.loadMessages()
        
        if !loadedMessages.isEmpty {
            self.messages = loadedMessages
        } else {
            // Миграция со старого UserDefaults
            if let data = UserDefaults.standard.data(forKey: "savedChatMessages"),
               let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) {
                self.messages = decoded
                // Сразу сохраняем в новый файл, чтобы в следующий раз грузить оттуда
                ChatHistoryManager.shared.saveMessages(self.messages)
                // Удаляем из UserDefaults, чтобы не занимать место
                UserDefaults.standard.removeObject(forKey: "savedChatMessages")
            }
        }
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
            
            let fs = FileSystemManager(workspaceURL: url)
            self.fileSystem = fs
            
            let ts = ToolExecutionService(fileSystem: fs)
            self.toolService = ts
            
            self.orchestrator = AIOrchestrator(aiClient: aiClient, toolService: ts, fileSystem: fs)
        } else if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
            self.workspaceURL = url
            
            let fs = FileSystemManager(workspaceURL: url)
            self.fileSystem = fs
            
            let ts = ToolExecutionService(fileSystem: fs)
            self.toolService = ts
            
            self.orchestrator = AIOrchestrator(aiClient: aiClient, toolService: ts, fileSystem: fs)
        }
    }
}
