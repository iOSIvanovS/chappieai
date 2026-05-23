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

    /// Клиент API — хранится как var, потому что может быть пересоздан при смене ключа.
    /// ПОЧЕМУ VAR: при вызове updateApiKey() мы создаём новый экземпляр AITunnelClient
    /// с обновлённым ключом. Если бы это было let — смена ключа потребовала бы перезапуска.
    private var aiClient: AITunnelClient

    private var orchestrator: AIOrchestrator?
    
    // MARK: - Менеджер истории чата
    // Ключевое свойство: держим актуальный экземпляр ChatHistoryManager,
    // привязанный к текущему воркспейсу. Это позволяет изолировать историю
    // каждого проекта в отдельном файле внутри папки проекта.
    // При смене воркспейса этот экземпляр заменяется новым — UI автоматически
    // перерисовывает историю именно для выбранного проекта.
    private var chatHistoryManager: ChatHistoryManager
    
    // MARK: - Инициализация
    
    public init() {
        // ИСПРАВЛЕНИЕ БАГ-1: API-ключ больше НЕ захардкожен в коде.
        // Теперь он читается из SettingsManager, который хранит его в UserDefaults.
        // Если ключ не задан — передаём пустую строку; AITunnelClient вернёт понятную ошибку
        // при попытке сделать запрос, а UI покажет кнопку настроек.
        let savedKey = SettingsManager.shared.apiKey
        self.aiClient = AITunnelClient(apiKey: savedKey)
        
        // На старте воркспейс ещё не выбран — используем глобальный фолбэк-менеджер
        // истории (ChatHistoryManager.shared), который хранит данные в стандартном
        // Documents/Chappie. Как только воркспейс будет загружен/восстановлен,
        // chatHistoryManager заменится на экземпляр, привязанный к папке проекта.
        self.chatHistoryManager = ChatHistoryManager.shared
        
        loadMessages()
        
        if let savedBalance = UserDefaults.standard.object(forKey: "savedBalance") as? Double {
            self.currentBalance = savedBalance
        }
        
        // Восстанавливаем сохраненный воркспейс при запуске приложения.
        loadWorkspaceWithSecurityScope()
    }
    
    // MARK: - Публичные методы управления API-ключом
    
    /// Обновляет API-ключ и пересоздаёт AITunnelClient с новым ключом.
    ///
    /// ПОЧЕМУ НУЖЕН ЭТОТ МЕТОД:
    /// AITunnelClient создаётся в init() с ключом, актуальным на момент запуска.
    /// Если пользователь меняет ключ в настройках, нам нужно пересоздать клиент —
    /// иначе до перезапуска приложения будет использоваться старый ключ.
    /// Этот метод вызывается из SettingsView через коллбэк onApiKeyChanged.
    func updateApiKey(_ newKey: String) {
        // Пересоздаём клиент с новым ключом
        self.aiClient = AITunnelClient(apiKey: newKey)
        
        // Пересоздаём оркестратор, так как он держит ссылку на старый aiClient.
        // Без этого оркестратор продолжит использовать старый клиент.
        if let ts = toolService, let fs = fileSystem {
            self.orchestrator = AIOrchestrator(aiClient: aiClient, toolService: ts, fileSystem: fs)
        }
        
        messages.append(ChatMessage(isUser: false, text: "✅ API-ключ обновлён. Готов к работе!"))
    }
    
    // MARK: - Публичные методы управления воркспейсом
    
    /// Подключает новую папку проекта к приложению Chappie.
    /// Пересоздаёт все связанные сервисы и запускает автоматическую инициализацию памяти.
    /// - Parameter url: URL выбранной пользователем папки.
    func setWorkspace(_ url: URL) {
        workspaceURL = url
        
        // Инициализируем весь стек сервисов для нового воркспейса
        initializeServices(for: url)
        
        // Переключаем менеджер истории на новый воркспейс.
        // КРИТИЧНО: делаем это ДО loadMessages(), иначе прочитаем данные из предыдущего хранилища.
        chatHistoryManager = ChatHistoryManager(workspaceURL: url)
        loadMessages()
        
        // Сохраняем закладку доступа (Security-Scoped Bookmark) для macOS Sandbox
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
        
        // Проверяем наличие API-ключа перед отправкой.
        // Лучше сразу сказать пользователю о проблеме, чем получить сетевую ошибку.
        guard SettingsManager.shared.isApiKeyValid else {
            messages.append(ChatMessage(isUser: false, text: "⚠️ API-ключ не задан или некорректен. Откройте настройки (⚙️) и введите ключ AITunnel."))
            return
        }
        
        messages.append(ChatMessage(isUser: true, text: prompt))
        isThinking = true
        
        // Подготавливаем чистую историю для сетевого запроса.
        // Убираем системные приветствия и сервисные логи вызова инструментов,
        // чтобы не засорять контекст модели.
        let cleanHistory: [AIMessage] = messages.compactMap { msg -> AIMessage? in
            if msg.text.contains("Проект подключен") || msg.text.hasPrefix("🛠") { return nil }
            
            var content = msg.text
            // ОПТИМИЗАЦИЯ КОНТЕКСТА: удаляем огромные блоки кода из старых ответов ассистента,
            // заменяя их на лёгкие информативные заглушки. Если ИИ понадобится этот код снова,
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
                        // Коллбэк вызывается на каждом шаге, когда ИИ применяет инструмент.
                        // Выводим это в UI, чтобы пользователь видел "мыслительный процесс" Чаппи.
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
    
    // MARK: - Вспомогательные методы
    
    /// Очищает историю чата текущего воркспейса.
    func clearMessages() {
        messages = []
    }
    
    /// Полная очистка контекста с приветственным сообщением.
    func clearHistory() {
        messages.removeAll()
        messages.append(ChatMessage(isUser: false, text: "Память очищена. Я забыл всё, что мы обсуждали до этого момента. Готов начать с чистого листа!"))
    }
    
    // MARK: - Приватные методы инициализации сервисов
    
    /// Создаёт и связывает весь стек сервисов для указанного воркспейса.
    ///
    /// ПОЧЕМУ ВЫНЕСЕНО В ОТДЕЛЬНЫЙ МЕТОД:
    /// Раньше идентичный блок из ~15 строк дублировался в setWorkspace() и loadWorkspaceWithSecurityScope().
    /// Любое изменение (например, добавление нового сервиса) требовало правки в двух местах —
    /// классический источник багов. Теперь это единственное место инициализации стека.
    private func initializeServices(for url: URL) {
        // 1. Файловая система — базовый сервис, от которого зависят остальные
        let fs = FileSystemManager(workspaceURL: url)
        self.fileSystem = fs
        
        // 2. Менеджер памяти — читает/пишет AI_Docs внутри воркспейса
        let mm = MemoryManager(workspaceURL: url)
        self.memoryManager = mm
        
        // КРИТИЧЕСКИЙ АВТОМАТИЗМ:
        // Запускаем инициализацию памяти воркспейса СТРОГО в момент подключения папки.
        // Это гарантирует, что папки AI_Docs и файлы semantic.json, architecture.md, project_map.md
        // будут проверены и созданы (если их нет) сразу, не дожидаясь первого вызова инструмента.
        Task {
            await mm.initializeWorkspaceMemory()
        }
        
        // 3. Сервис выполнения инструментов — оборачивает fs и mm в вызываемые инструменты
        let ts = ToolExecutionService(fileSystem: fs, memoryManager: mm)
        self.toolService = ts
        
        // 4. Оркестратор — мозг системы, координирует цикл reasoning + tool calls
        self.orchestrator = AIOrchestrator(aiClient: aiClient, toolService: ts, fileSystem: fs)
    }
    
    // MARK: - Очистка текста
    
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
    
    /// Сохраняет текущий массив сообщений через актуальный менеджер истории.
    /// Вызывается автоматически через didSet при каждом изменении messages.
    private func saveMessages() {
        chatHistoryManager.saveMessages(messages)
    }
    
    /// Загружает историю сообщений через актуальный менеджер истории.
    /// Вызывается при инициализации и при смене воркспейса.
    private func loadMessages() {
        let loadedMessages: [ChatMessage] = chatHistoryManager.loadMessages()
        
        if !loadedMessages.isEmpty {
            self.messages = loadedMessages
        } else {
            // Проверяем legacy-хранилище UserDefaults для миграции данных
            // пользователей, обновившихся со старой версии приложения.
            if let data = UserDefaults.standard.data(forKey: "savedChatMessages"),
               let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) {
                self.messages = decoded
                // Мигрируем в новое хранилище и удаляем старый ключ
                chatHistoryManager.saveMessages(self.messages)
                UserDefaults.standard.removeObject(forKey: "savedChatMessages")
            }
        }
    }
    
    // MARK: - Работа с Security-Scoped Bookmarks (macOS Sandbox)
    
    /// Сохраняет URL папки в виде Security-Scoped Bookmark в UserDefaults.
    /// Это позволяет приложению получать доступ к папке при следующих запусках
    /// без повторного показа NSOpenPanel.
    private func saveWorkspaceWithSecurityScope(_ url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: "workspaceBookmark")
        } catch {
            // Фолбэк для не-песочного режима разработки
            if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(data, forKey: "workspaceBookmark")
            }
        }
    }
    
    /// Восстанавливает доступ к ранее выбранной папке проекта и инициализирует все сервисы.
    private func loadWorkspaceWithSecurityScope() {
        guard let data = UserDefaults.standard.data(forKey: "workspaceBookmark") else { return }
        var isStale = false
        
        // Пытаемся восстановить как Security-Scoped URL (режим Sandbox)
        let secureURL = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        
        if let url = secureURL {
            _ = url.startAccessingSecurityScopedResource()
            self.workspaceURL = url
            initializeServices(for: url)
            chatHistoryManager = ChatHistoryManager(workspaceURL: url)
            loadMessages()
            
            // Если закладка устарела — обновляем её
            if isStale { saveWorkspaceWithSecurityScope(url) }
            
        } else {
            // Фолбэк: пробуем без Security Scope (для не-песочного режима разработки)
            let fallbackURL = try? URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            if let url = fallbackURL {
                self.workspaceURL = url
                initializeServices(for: url)
                chatHistoryManager = ChatHistoryManager(workspaceURL: url)
                loadMessages()
            }
        }
    }
}
