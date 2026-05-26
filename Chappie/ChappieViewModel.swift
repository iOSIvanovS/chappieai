// ChappieViewModel.swift
// Chappie
//
// Главная ViewModel приложения Chappie.
// Управляет состоянием интерфейса, хранит историю сообщений, инициализирует сервисы
// и координирует работу ИИ-оркестратора.
//
// АРХИТЕКТУРА ИСТОРИИ (КРИТИЧЕСКИ ВАЖНО):
//
// ПРОБЛЕМА КОТОРУЮ МЫ РЕШИЛИ:
// Раньше история собиралась ДВАЖДЫ:
//   1. ChappieViewModel.buildNetworkHistory() — с параметрами tokenBudget=30,000, recentFullCount=6
//   2. AIOrchestrator.buildContextWindow() — с параметрами из AppConfig (tokenBudget=12,000, recentFullCount=3)
// Оркестратор получал уже сжатую историю и сжимал её снова. Параметры рассинхронизированы.
// Результат: 21,000+ токенов на запрос вместо ожидаемых 5,000-7,000.
//
// РЕШЕНИЕ:
// ViewModel больше НЕ строит токенное окно. Она передаёт в оркестратор ПОЛНУЮ сырую историю
// в формате [AIMessage]. Оркестратор — единственное место, где применяется buildContextWindow().
// ViewModel отвечает только за:
//   1. Хранение ChatMessage (UI-тип с .toolCall и .message)
//   2. Конвертацию .message → AIMessage (сетевой тип) БЕЗ сжатия
//   3. Парсинг <summary> из финального ответа
//
// ПАРАМЕТРЫ — ОДИН ИСТОЧНИК ИСТИНЫ (IT-02):
// С IT-02 все параметры контекста (tokenBudget, maxMessagesInContext) хранятся в ThreadSettings.
// ViewModel создаёт AppConfig из настроек активного треда и передаёт его в process().
// AppConfig.shared используется как дефолт пока тред не выбран (до IT-05).
//
// ТРЁХУРОВНЕВАЯ ПАМЯТЬ (IT-03):
// MemoryStore (SwiftData) подключается к MemoryManager через setMemoryStore().
// AIOrchestrator.process() получает MemoryContext (threadId + projectIds).
// Перед каждым запросом MemoryManager.buildSystemPrompt() автоматически подмешивает
// глобальную + проектную + тредовую память в system prompt.
// До IT-05 (UI тредов) — activeMemoryContext = .empty (только базовый промпт).
//
// АРХИТЕКТУРА ЗАПУСКА ХЕЛПЕРА (MCPHelperLauncher):
// ПРОБЛЕМА: если запускать MCPHelperLauncher.shared.launch() без пути (из ChappieApp.onAppear),
// хелпер получает FileManager.currentDirectoryPath = "/" как воркспейс.
// Git не находит репозиторий, все команды падают.
//
// РЕШЕНИЕ: хелпер запускается ТОЛЬКО когда путь к воркспейсу известен:
//   а) loadWorkspaceWithSecurityScope() — восстановление при старте → launch(workspacePath:)
//   б) setWorkspace() — ручной выбор папки → restartWithWorkspace()
// ChappieApp.onAppear больше НЕ вызывает launch() — там путь ещё неизвестен.

import SwiftUI
import ChappieCore
import SwiftData

/// Главная ViewModel приложения Chappie.
///
/// Зачем @Observable + @MainActor:
///   - @Observable (Swift 5.9+) заменяет ObservableObject + @Published.
///     SwiftUI автоматически отслеживает только те свойства, которые реально
///     читаются в body — это точечные, а не массовые перерисовки.
///   - @MainActor гарантирует, что все изменения свойств происходят на главном потоке,
///     что обязательно для безопасного обновления UI из async-контекста.
@Observable
@MainActor
final class ChappieViewModel {

    // MARK: - Свойства состояния

    /// Текущая выбранная папка проекта (workspace).
    var workspaceURL: URL?

    /// Полная история сообщений — хранится в памяти и на диске.
    ///
    /// ВАЖНО: Этот массив содержит ВСЕ записи, включая .toolCall.
    /// В UI напрямую НЕ передаётся — используй `visibleMessages`.
    /// В оркестратор передаётся через `buildRawNetworkHistory()` — только .message,
    /// без сжатия. Сжатие выполняет AIOrchestrator через buildContextWindow().
    /// `didSet` автоматически сохраняет историю на диск при каждом изменении.
    var messages: [ChatMessage] = [] {
        didSet { saveMessages() }
    }

    /// Отфильтрованный список сообщений для отображения в UI.
    var visibleMessages: [ChatMessage] {
        let onlyMessages = messages.filter { msg in
            if case .message = msg { return true }
            return false
        }
        return Array(onlyMessages.suffix(30))
    }

    var isThinking = false
    var streamingText: String = ""
    var runningCost: Double = 0.0
    var currentToolCall: String? = nil

    /// Текущий баланс пользователя в рублях.
    var currentBalance: Double? {
        didSet { UserDefaults.standard.set(currentBalance, forKey: "savedBalance") }
    }

    // MARK: - Настройки активного треда (IT-02)

    /// Настройки активного треда — определяют глубину контекста и токенный бюджет.
    var activeThreadSettings: ThreadSettings = ThreadSettings()

    /// Создаёт AppConfig из настроек активного треда.
    private var activeConfig: AppConfig {
        AppConfig(settings: activeThreadSettings)
    }

    // MARK: - Контекст памяти для system prompt (IT-03)

    /// Контекст треда для подмешивания трёхуровневой памяти в system prompt.
    ///
    /// АРХИТЕКТУРНОЕ РЕШЕНИЕ (IT-03):
    /// MemoryContext содержит threadId и projectIds — всё что нужно MemoryManager
    /// для сборки полного system prompt с памятью.
    ///
    /// ДЕФОЛТ: .empty — только базовый промпт без памяти.
    /// Заполняется из активного треда в IT-05 (UI боковой панели).
    /// До IT-05 — используется .empty (обратная совместимость).
    var activeMemoryContext: MemoryContext = .empty

    // MARK: - Зависимости (Сервисы)

    private var fileSystem: FileSystemManager?
    private var memoryManager: MemoryManager?
    private var toolService: ToolExecutionService?

    private var aiClient: AITunnelClient
    private var orchestrator: AIOrchestrator?
    private var chatHistoryManager: ChatHistoryManager

    // MARK: - SwiftData (IT-03)

    /// Контейнер SwiftData — передаётся из ChappieApp через setModelContainer().
    ///
    /// ПОЧЕМУ ОПЦИОНАЛЬНЫЙ:
    /// ChappieViewModel инициализируется до того как ModelContainer готов в App.
    /// Контейнер передаётся позже через setModelContainer() из ContentView.onAppear.
    private var modelContainer: ModelContainer?

    /// MemoryStore — SwiftData бэкенд для трёхуровневой памяти.
    ///
    /// Создаётся в setModelContainer() после получения ModelContainer.
    /// Сразу подключается к MemoryManager через setMemoryStore().
    private var memoryStore: MemoryStore?

    // MARK: - Инициализация

    public init() {
        let savedKey = SettingsManager.shared.apiKey
        self.aiClient = AITunnelClient(apiKey: savedKey)
        self.chatHistoryManager = ChatHistoryManager.shared

        loadMessages()

        if let savedBalance = UserDefaults.standard.object(forKey: "savedBalance") as? Double {
            self.currentBalance = savedBalance
        }

        loadWorkspaceWithSecurityScope()
    }

    // MARK: - Подключение SwiftData (IT-03)

    /// Подключает ModelContainer к ViewModel — вызывается из ContentView.onAppear.
    ///
    /// ПОЧЕМУ НЕ В INIT:
    /// ModelContainer создаётся в ChappieApp (App-уровень) и недоступен при init ViewModel.
    /// Стандартная практика: передавать через метод после инициализации.
    ///
    /// ЧТО ПРОИСХОДИТ:
    /// 1. Создаётся MemoryStore с переданным контейнером
    /// 2. MemoryStore подключается к MemoryManager через setMemoryStore()
    /// 3. После этого buildSystemPrompt() начинает читать из SwiftData
    func setModelContainer(_ container: ModelContainer) {
        guard self.modelContainer == nil else { return } // Идемпотентность — не пересоздаём

        self.modelContainer = container

        // Создаём MemoryStore и подключаем к MemoryManager
        let store = MemoryStore(modelContainer: container)
        self.memoryStore = store

        // Подключаем к MemoryManager если он уже создан (воркспейс был восстановлен)
        if let mm = memoryManager {
            Task {
                await mm.setMemoryStore(store)
            }
        }

        print("[ChappieViewModel] ✅ ModelContainer подключён, MemoryStore создан")
    }

    // MARK: - Управление API-ключом

    func updateApiKey(_ newKey: String) {
        self.aiClient = AITunnelClient(apiKey: newKey)

        if let ts = toolService, let fs = fileSystem, let mm = memoryManager {
            self.orchestrator = AIOrchestrator(
                aiClient: aiClient,
                toolService: ts,
                fileSystem: fs,
                memoryManager: mm
            )
        }

        messages.append(.message(isUser: false, text: "✅ API-ключ обновлён. Готов к работе!"))
    }

    // MARK: - Управление воркспейсом

    func setWorkspace(_ url: URL) {
        workspaceURL = url
        initializeServices(for: url)
        chatHistoryManager = ChatHistoryManager(workspaceURL: url)
        loadMessages()
        saveWorkspaceWithSecurityScope(url)
        MCPHelperLauncher.shared.restartWithWorkspace(url)

        if messages.isEmpty {
            messages.append(.message(isUser: false, text: "Проект подключен. Я готов к работе!"))
        }
    }

    // MARK: - Отправка сообщений и оркестрация

    /// Отправляет запрос пользователя в ИИ-оркестратор и запускает многошаговый цикл.
    ///
    /// ТРЁХУРОВНЕВАЯ ПАМЯТЬ (IT-03):
    /// В process() передаётся activeMemoryContext — контекст треда для сборки промпта.
    /// До IT-05 activeMemoryContext = .empty → только базовый промпт (обратная совместимость).
    func send(prompt: String) {
        guard !prompt.isEmpty else { return }
        guard let orchestrator = orchestrator else {
            messages.append(.message(isUser: false, text: "Ошибка: Оркестратор не инициализирован. Подключите папку с проектом."))
            return
        }

        guard SettingsManager.shared.isApiKeyValid else {
            messages.append(.message(isUser: false, text: "⚠️ API-ключ не задан или некорректен. Откройте настройки (⚙️) и введите ключ AITunnel."))
            return
        }

        messages.append(.message(isUser: true, text: prompt))
        isThinking = true
        streamingText = ""
        currentToolCall = nil
        runningCost = 0.0

        let networkHistory = buildRawNetworkHistory()

        // Захватываем конфиг и контекст памяти ДО входа в Task.
        // Оба типа — Sendable value types, безопасно захватывать в замыкание.
        let config = activeConfig
        let memoryContext = activeMemoryContext

        Task {
            do {
                let result = try await orchestrator.process(
                    prompt: prompt,
                    history: networkHistory,
                    config: config,
                    memoryContext: memoryContext,
                    onToolCall: { toolName, targetPath in
                        Task { @MainActor in
                            if targetPath.isEmpty {
                                self.currentToolCall = toolName
                            } else {
                                let shortPath = targetPath.split(separator: "/").suffix(2).joined(separator: "/")
                                self.currentToolCall = "\(toolName) → \(shortPath)"
                            }
                        }
                    },
                    onToken: { token in
                        Task { @MainActor in
                            self.streamingText += token
                        }
                    },
                    onCostUpdate: { cumulativeCost in
                        Task { @MainActor in
                            self.runningCost = cumulativeCost
                        }
                    }
                )

                let rawResponse = self.cleanAIResponse(result.finalResponse)
                let (displayText, summary) = self.extractAndCleanSummary(from: rawResponse)
                let finalCost = result.totalCost

                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    self.streamingText = ""
                    self.currentToolCall = nil
                    self.messages.append(.message(
                        isUser: false,
                        text: displayText,
                        cost: finalCost,
                        summary: summary
                    ))
                }

                if let newBalance = result.newBalance {
                    self.currentBalance = newBalance
                }
            } catch {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    self.streamingText = ""
                    self.currentToolCall = nil
                    self.messages.append(.message(isUser: false, text: "Упс, ошибка: \(error.localizedDescription)"))
                }
            }

            isThinking = false
        }
    }

    // MARK: - Управление историей

    func clearMessages() {
        messages = []
    }

    func clearHistory() {
        messages.removeAll()
        messages.append(.message(isUser: false, text: "Память очищена. Я забыл всё, что мы обсуждали до этого момента. Готов начать с чистого листа!"))
    }

    // MARK: - Конвертация истории в сетевой формат (БЕЗ сжатия)

    private func buildRawNetworkHistory() -> [AIMessage] {
        return messages.compactMap { msg -> AIMessage? in
            guard case .message(_, let isUser, let text, _, let summary) = msg else {
                return nil
            }

            let isSystemMessage = text.contains("Проект подключен")
                || text.contains("Память очищена")
                || text.contains("API-ключ обновлён")
                || text.hasPrefix("⚠️ API-ключ")
                || text.hasPrefix("Ошибка:")
                || text.hasPrefix("Упс, ошибка:")

            if isSystemMessage { return nil }

            let role = isUser ? "user" : "assistant"

            if !isUser, let summary = summary {
                let textWithSummary = text + "\n<summary>\(summary)</summary>"
                return AIMessage(role: role, content: textWithSummary)
            }

            return AIMessage(role: role, content: text)
        }
    }

    // MARK: - Парсинг Self-Summary

    private func extractAndCleanSummary(from text: String) -> (displayText: String, summary: String?) {
        guard let regex = try? NSRegularExpression(
            pattern: "<summary>(.*?)</summary>",
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else {
            return (text, nil)
        }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        guard let lastMatch = matches.last,
              let summaryRange = Range(lastMatch.range(at: 1), in: text),
              let fullMatchRange = Range(lastMatch.range, in: text) else {
            return (text, nil)
        }

        let summary = String(text[summaryRange]).trimmingCharacters(in: .whitespacesAndNewlines)

        var displayText = text
        displayText.removeSubrange(fullMatchRange)
        displayText = displayText.trimmingCharacters(in: .whitespacesAndNewlines)

        let finalDisplayText = displayText.isEmpty ? summary : displayText

        return (finalDisplayText, summary.isEmpty ? nil : summary)
    }

    // MARK: - Приватные методы инициализации сервисов

    /// Создаёт и связывает весь стек сервисов для указанного воркспейса.
    ///
    /// ТРЁХУРОВНЕВАЯ ПАМЯТЬ (IT-03):
    /// После создания MemoryManager — подключаем MemoryStore если он уже есть.
    /// Это происходит если setModelContainer() был вызван до setWorkspace().
    /// Если MemoryStore ещё нет — он подключится позже в setModelContainer().
    private func initializeServices(for url: URL) {
        let fs = FileSystemManager(workspaceURL: url)
        self.fileSystem = fs

        let mm = MemoryManager(workspaceURL: url)
        self.memoryManager = mm

        Task {
            await mm.initializeWorkspaceMemory()

            // Подключаем MemoryStore к новому MemoryManager если он уже создан.
            // Это важно при смене воркспейса — новый MemoryManager должен получить
            // тот же MemoryStore (SwiftData контейнер один на всё приложение).
            if let store = self.memoryStore {
                await mm.setMemoryStore(store)
            }
        }

        let socketPath = MCPHelperLauncher.shared.socketPath

        let ts = ToolExecutionService(fileSystem: fs, memoryManager: mm, socketPath: socketPath)
        self.toolService = ts

        // ИЗМЕНЕНИЕ IT-03: AIOrchestrator теперь принимает memoryManager как параметр.
        // Это позволяет ему вызывать buildSystemPrompt() перед каждым запросом.
        self.orchestrator = AIOrchestrator(
            aiClient: aiClient,
            toolService: ts,
            fileSystem: fs,
            memoryManager: mm
        )
    }

    // MARK: - Очистка текста ответа

    private func cleanAIResponse(_ text: String) -> String {
        var cleanedText = text
        if let regex = try? NSRegularExpression(
            pattern: "94>thought.*?needed\\.\\n*",
            options: [.dotMatchesLineSeparators]
        ) {
            cleanedText = regex.stringByReplacingMatches(
                in: cleanedText,
                options: [],
                range: NSRange(location: 0, length: cleanedText.utf16.count),
                withTemplate: ""
            )
        }
        return cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Локальное сохранение истории

    private func saveMessages() {
        chatHistoryManager.saveMessages(messages)
    }

    private func loadMessages() {
        let loadedMessages: [ChatMessage] = chatHistoryManager.loadMessages()

        if !loadedMessages.isEmpty {
            self.messages = loadedMessages
        } else {
            if let data = UserDefaults.standard.data(forKey: "savedChatMessages"),
               let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) {
                self.messages = decoded
                chatHistoryManager.saveMessages(self.messages)
                UserDefaults.standard.removeObject(forKey: "savedChatMessages")
            }
        }
    }

    // MARK: - Security-Scoped Bookmarks (macOS Sandbox)

    private func saveWorkspaceWithSecurityScope(_ url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: "workspaceBookmark")
        } catch {
            if let data = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                UserDefaults.standard.set(data, forKey: "workspaceBookmark")
            }
        }
    }

    private func loadWorkspaceWithSecurityScope() {
        guard let data = UserDefaults.standard.data(forKey: "workspaceBookmark") else { return }
        var isStale = false

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
            if isStale { saveWorkspaceWithSecurityScope(url) }
            MCPHelperLauncher.shared.launch(workspacePath: url.path)

        } else {
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
                MCPHelperLauncher.shared.launch(workspacePath: url.path)
            }
        }
    }
}
