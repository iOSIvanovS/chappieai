//
//  ChappieViewModel.swift
//  Chappie
//
//  Created by Сергей on 21.05.2026.
//

import SwiftUI
import ChappieCore

/// Модель сообщения для отображения в интерфейсе чата.
public struct ChatMessage: Identifiable, Hashable, Codable {
    public var id = UUID()
    public let isUser: Bool
    public let text: String
    public var cost: Double? = nil
}

/// Главная ViewModel приложения Chappie.
/// Управляет состоянием интерфейса, хранит историю сообщений, инициализирует сервисы
/// и координирует работу ИИ-оркестратора.
@Observable
@MainActor
final class ChappieViewModel {
    
    // MARK: - Свойства состояния
    
    /// Текущая выбранная папка проекта (workspace).
    var workspaceURL: URL?
    
    /// История сообщений в чате. При изменении автоматически сохраняется на диск.
    var messages: [ChatMessage] = [] {
        didSet { saveMessages() }
    }
    
    /// Флаг, показывающий, что ИИ сейчас размышляет (выполняет шаги оркестрации).
    var isThinking = false
    
    /// Текущий баланс пользователя в рублях (загружается из API AITunnel).
    var currentBalance: Double? {
        didSet { UserDefaults.standard.set(currentBalance, forKey: "savedBalance") }
    }
    
    // MARK: - Зависимости (Сервисы)
    
    private var fileSystem: FileSystemManager?
    private var memoryManager: MemoryManager?
    private var toolService: ToolExecutionService?
    private var aiClient: AITunnelClient
    private var orchestrator: AIOrchestrator?
    
    // MARK: - Инициализация
    
    public init() {
        // Дефолтный ключ API AITunnel для разработки.
        let defaultKey = "REMOVED_API_KEY"
        let savedKey = UserDefaults.standard.string(forKey: "aiTunnelApiKey") ?? defaultKey
        self.aiClient = AITunnelClient(apiKey: savedKey)
        
        loadMessages()
        
        if let savedBalance = UserDefaults.standard.object(forKey: "savedBalance") as? Double {
            self.currentBalance = savedBalance
        }
        
        // Восстанавливаем сохраненный воркспейс при запуске приложения.
        loadWorkspaceWithSecurityScope()
    }
    
    // MARK: - Публичные методы управления воркспейсом
    
    /// Подключает новую папку проекта к приложению Chappie.
    /// Пересоздаёт все связанные сервисы и запускает автоматическую инициализацию памяти.
    /// - Parameter url: URL выбранной пользователем папки.
    func setWorkspace(_ url: URL) {
        workspaceURL = url
        
        // 1. Создаем менеджер файловой системы для нового воркспейса
        let fs = FileSystemManager(workspaceURL: url)
        self.fileSystem = fs
        
        // 2. Создаем менеджер памяти
        let mm = MemoryManager(workspaceURL: url)
        self.memoryManager = mm
        
        // КРИТИЧЕСКИЙ АВТОМАТИЗМ (Решение нашей проблемы с детерминизмом памяти):
        // Мы запускаем инициализацию памяти воркспейса СТРОГО и явно в момент выбора папки.
        // Это гарантирует, что папки AI_Docs и файлы semantic.json, architecture.md, project_map.md
        // будут проверены и созданы (если их нет) при каждом подключении проекта, 
        // не дожидаясь, пока ИИ решит вызвать инструмент работы с памятью.
        Task {
            await mm.initializeWorkspaceMemory()
        }
        
        // 3. Инициализируем сервисы выполнения инструментов и оркестратор
        let defaultKey = "REMOVED_API_KEY"
        let savedKey = UserDefaults.standard.string(forKey: "aiTunnelApiKey") ?? defaultKey
        let ts = ToolExecutionService(fileSystem: fs, memoryManager: mm, apiKey: savedKey)
        self.toolService = ts
        
        self.orchestrator = AIOrchestrator(aiClient: aiClient, toolService: ts, fileSystem: fs)
        
        // 4. Сохраняем закладку доступа (Security-Scoped Bookmark) для macOS Sandbox
        saveWorkspaceWithSecurityScope(url)
        
        if messages.isEmpty {
            messages.append(ChatMessage(isUser: false, text: "Проект подключен. Я готов к работе!"))
        }
    }
    
    // MARK: - Отправка сообщений и оркестрация
    
    /// Отправляет запрос пользователя в ИИ-оркестратор и запускает многошаговый цикл решения задачи.
    /// - Parameter prompt: Текст запроса.
    func send(prompt: String) {
        guard !prompt.isEmpty else { return }
        guard let orchestrator = orchestrator else {
            messages.append(ChatMessage(isUser: false, text: "Ошибка: Оркестратор не инициализирован. Подключите папку с проектом."))
            return
        }
        
        messages.append(ChatMessage(isUser: true, text: prompt))
        isThinking = true
        
        // Подготавливаем чистую историю для сетевого запроса.
        // Мы убираем системные приветствия и сервисные логи вызова инструментов, чтобы не засорять контекст.
        let cleanHistory: [AIMessage] = messages.compactMap { msg -> AIMessage? in
            if msg.text.contains("Проект подключен") || msg.text.hasPrefix("🛠") { return nil }
            
            var content = msg.text
            // ОПТИМИЗАЦИЯ КОНТЕКСТА: удаляем огромные блоки кода из старых ответов ассистента в истории,
            // заменяя их на легкие информативные заглушки. Если ИИ понадобится этот код снова,
            // он сможет прочитать его с диска с помощью инструмента read_file. 
            // Это экономит до 90% токенов в длинных диалогах!
            if !msg.isUser {
                content = self.stripCodeBlocks(from: content)
            }
            
            return AIMessage(role: msg.isUser ? "user" : "assistant", content: content)
        }
        
        let historyLimit = AppConfig.shared.maxHistoryMessages
        let networkHistory = Array(cleanHistory.suffix(historyLimit))
        
        Task {
            do {
                // Запускаем процесс оркестрации
                let result = try await orchestrator.process(
                    prompt: prompt,
                    history: networkHistory,
                    onToolCall: { toolName, targetPath in
                        // Данный коллбэк вызывается на каждом шаге, когда ИИ решает применить инструмент.
                        // Мы выводим это в UI, чтобы пользователь видел "мыслительный процесс" и работу Чаппи в реальном времени.
                        Task { @MainActor in
                            self.messages.append(ChatMessage(isUser: false, text: "🛠 Выполняю: \(toolName) -> \(targetPath)", cost: nil))
                        }
                    }
                )
                
                // Очищаем ответ от технических тегов рассуждений и выводим пользователю
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
    
    // MARK: - Вспомогательные методы очистки текста
    
    /// Удаляет технические теги размышлений из финального ответа ИИ для чистого отображения в UI.
    private func cleanAIResponse(_ text: String) -> String {
        var cleanedText = text
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
    
    /// Заменяет блоки кода в истории на заглушки для экономии токенов контекста.
    private func stripCodeBlocks(from text: String) -> String {
        let pattern = "```[a-zA-Z]*\\n.*?```"
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
            return regex.stringByReplacingMatches(
                in: text,
                options: [],
                range: NSRange(location: 0, length: text.utf16.count),
                withTemplate: "\n[Код скрыт из истории для экономии контекста. Если он тебе нужен, прочитай файл через read_file]\n"
            )
        }
        return text
    }
    
    // MARK: - Локальное сохранение и восстановление истории чата
    
    private func saveMessages() {
        ChatHistoryManager.shared.saveMessages(messages)
    }
    
    private func loadMessages() {
        let loadedMessages: [ChatMessage] = ChatHistoryManager.shared.loadMessages()
        
        if !loadedMessages.isEmpty {
            self.messages = loadedMessages
        } else {
            // Фолбэк на старое место хранения в UserDefaults (для обратной совместимости)
            if let data = UserDefaults.standard.data(forKey: "savedChatMessages"),
               let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) {
                self.messages = decoded
                ChatHistoryManager.shared.saveMessages(self.messages)
                UserDefaults.standard.removeObject(forKey: "savedChatMessages") // Очищаем старый ключ
            }
        }
    }
    
    // MARK: - Работа с Security-Scoped Bookmarks (macOS Sandbox)
    
    /// Сохраняет URL папки в виде Security-Scoped Bookmark в UserDefaults.
    /// Это позволяет приложению получать доступ к этой папке при следующих запусках без повторного показа NSOpenPanel.
    private func saveWorkspaceWithSecurityScope(_ url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmarkData, forKey: "workspaceBookmark")
        } catch {
            // Если песочница отключена или произошла ошибка, сохраняем обычный Bookmark как фолбэк
            if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(data, forKey: "workspaceBookmark")
            }
        }
    }
    
    /// Восстанавливает доступ к ранее выбранной папке проекта и инициализирует все сервисы.
    private func loadWorkspaceWithSecurityScope() {
        guard let data = UserDefaults.standard.data(forKey: "workspaceBookmark") else { return }
        var isStale = false
        
        // Пытаемся восстановить как Security-Scoped URL
        if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
            _ = url.startAccessingSecurityScopedResource()
            self.workspaceURL = url
            
            let fs = FileSystemManager(workspaceURL: url)
            self.fileSystem = fs
            
            let mm = MemoryManager(workspaceURL: url)
            self.memoryManager = mm
            
            // КРИТИЧЕСКИЙ АВТОМАТИЗМ (Решение нашей проблемы с детерминизмом памяти):
            // Запускаем инициализацию памяти воркспейса СТРОГО и явно при авто-восстановлении папки при старте приложения.
            // Это гарантирует, что папки AI_Docs и файлы semantic.json, architecture.md, project_map.md
            // будут проверены и созданы (если их нет) при каждом запуске приложения автоматически!
            Task {
                await mm.initializeWorkspaceMemory()
            }
            
            let defaultKey = "REMOVED_API_KEY"
            let savedKey = UserDefaults.standard.string(forKey: "aiTunnelApiKey") ?? defaultKey
            let ts = ToolExecutionService(fileSystem: fs, memoryManager: mm, apiKey: savedKey)
            self.toolService = ts
            
            self.orchestrator = AIOrchestrator(aiClient: aiClient, toolService: ts, fileSystem: fs)
            
        } else if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
            // Фолбэк для не-песочного режима
            self.workspaceURL = url
            
            let fs = FileSystemManager(workspaceURL: url)
            self.fileSystem = fs
            
            let mm = MemoryManager(workspaceURL: url)
            self.memoryManager = mm
            
            // Повторяем критический автоматизм для фолбэк-ветки
            Task {
                await mm.initializeWorkspaceMemory()
            }
            
            let defaultKey = "REMOVED_API_KEY"
            let savedKey = UserDefaults.standard.string(forKey: "aiTunnelApiKey") ?? defaultKey
            let ts = ToolExecutionService(fileSystem: fs, memoryManager: mm, apiKey: savedKey)
            self.toolService = ts
            
            self.orchestrator = AIOrchestrator(aiClient: aiClient, toolService: ts, fileSystem: fs)
        }
    }
}
