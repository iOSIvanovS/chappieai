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
//
// СИСТЕМА ТРЕДОВ (IT-05):
// Каждый тред — это отдельная история сообщений в SwiftData.
// При выборе треда загружается его история из ThreadStore.
// При отправке сообщения — история сохраняется в активный тред.
// activeMemoryContext заполняется из активного треда (threadId + projectIds).
// ChatHistoryManager продолжает работать параллельно как legacy-фолбэк.
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

    // MARK: - Система тредов (IT-05)

    /// Список всех тредов — отображается в боковой панели.
    /// Сортируется по updatedAt DESC (последний активный — сверху).
    var threads: [ThreadMetadata] = []

    /// Активный тред (nil = нет выбранного треда, используется legacy ChatHistoryManager).
    ///
    /// ПОЧЕМУ ОПЦИОНАЛЬНЫЙ:
    /// При первом запуске (до миграции) треда ещё нет.
    /// После миграции IT-04 создаётся тред "Основной" — он становится активным.
    var activeThread: ThreadMetadata? = nil

    // MARK: - Настройки активного треда (IT-02)

    /// Настройки активного треда — определяют глубину контекста и токенный бюджет.
    ///
    /// ИСТОЧНИК ЗНАЧЕНИЙ:
    /// Загружается из ThreadStore при выборе треда.
    /// Если треда нет — дефолтные настройки (20 сообщений, 10,000 токенов).
    var activeThreadSettings: ThreadSettings = ThreadSettings()

    /// Создаёт AppConfig из настроек активного треда.
    private var activeConfig: AppConfig {
        AppConfig(settings: activeThreadSettings)
    }

    // MARK: - Контекст памяти для system prompt (IT-03, IT-05)

    /// Контекст треда для подмешивания трёхуровневой памяти в system prompt.
    ///
    /// АРХИТЕКТУРНОЕ РЕШЕНИЕ (IT-03 + IT-05):
    /// MemoryContext содержит threadId и projectIds — всё что нужно MemoryManager
    /// для сборки полного system prompt с памятью.
    ///
    /// Заполняется из активного треда при выборе/смене треда (IT-05).
    /// До IT-05 = .empty — только базовый промпт без памяти.
    var activeMemoryContext: MemoryContext = .empty

    // MARK: - Зависимости (Сервисы)

    private var fileSystem: FileSystemManager?
    private var memoryManager: MemoryManager?
    private var toolService: ToolExecutionService?

    private var aiClient: AITunnelClient
    private var orchestrator: AIOrchestrator?
    private var chatHistoryManager: ChatHistoryManager

    // MARK: - SwiftData (IT-03 + IT-04 + IT-05)

    /// Контейнер SwiftData — передаётся из ChappieApp через setModelContainer().
    private var modelContainer: ModelContainer?

    /// MemoryStore — SwiftData бэкенд для трёхуровневой памяти.
    private var memoryStore: MemoryStore?

    /// ThreadStore — SwiftData бэкенд для тредов.
    private var threadStore: ThreadStore?

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

    // MARK: - Подключение SwiftData (IT-03 + IT-04 + IT-05)

    /// Подключает ModelContainer к ViewModel — вызывается из ContentView.onAppear.
    ///
    /// ЧТО ПРОИСХОДИТ:
    /// 1. Создаётся MemoryStore с переданным контейнером
    /// 2. Создаётся ThreadStore с переданным контейнером
    /// 3. MemoryStore подключается к MemoryManager через setMemoryStore()
    /// 4. После этого buildSystemPrompt() начинает читать из SwiftData
    /// 5. Запускается MigrationService — переносит legacy-данные в SwiftData (один раз)
    /// 6. После миграции — загружается список тредов (IT-05)
    func setModelContainer(_ container: ModelContainer) {
        guard self.modelContainer == nil else { return } // Идемпотентность

        self.modelContainer = container

        let store = MemoryStore(modelContainer: container)
        self.memoryStore = store

        let tStore = ThreadStore(modelContainer: container)
        self.threadStore = tStore

        if let mm = memoryManager {
            Task {
                await mm.setMemoryStore(store)
            }
        }

        print("[ChappieViewModel] ✅ ModelContainer подключён, MemoryStore и ThreadStore созданы")

        Task {
            await runMigrationIfNeeded(threadStore: tStore, memoryStore: store)
            // После миграции загружаем треды и выбираем активный
            await loadThreadsAndSelectActive(from: tStore)
        }
    }

    // MARK: - Управление тредами (IT-05)

    /// Загружает все треды из ThreadStore и выбирает активный.
    ///
    /// ЛОГИКА ВЫБОРА АКТИВНОГО ТРЕДА:
    /// 1. Если уже есть activeThread — ищем его в загруженном списке (мог обновиться)
    /// 2. Если нет — выбираем первый (самый свежий, т.к. сортировка по updatedAt DESC)
    /// 3. Если тредов нет — создаём "Новый тред" автоматически
    ///
    /// ПОЧЕМУ АВТОСОЗДАНИЕ:
    /// Пользователь не должен видеть пустое приложение без треда.
    /// Всегда должен быть хотя бы один тред для работы.
    private func loadThreadsAndSelectActive(from store: ThreadStore) async {
        do {
            let loaded = try await store.loadThreads()
            self.threads = loaded

            if loaded.isEmpty {
                // Тредов нет — создаём первый автоматически
                let newId = try await store.createThread(title: "Новый тред")
                let refreshed = try await store.loadThreads()
                self.threads = refreshed
                if let newThread = refreshed.first(where: { $0.id == newId }) {
                    await selectThread(newThread)
                }
            } else if let current = activeThread,
                      let updated = loaded.first(where: { $0.id == current.id }) {
                // Обновляем метаданные текущего треда (мог переименоваться)
                self.activeThread = updated
                self.activeMemoryContext = MemoryContext(
                    threadId: updated.id,
                    projectIds: updated.projectIds
                )
            } else {
                // Выбираем первый тред (самый свежий)
                await selectThread(loaded[0])
            }
        } catch {
            print("[ChappieViewModel] ⚠️ Ошибка загрузки тредов: \(error)")
        }
    }

    /// Выбирает тред — загружает его историю и обновляет контекст памяти.
    ///
    /// ПОЧЕМУ ASYNC:
    /// Загрузка сообщений из SwiftData — асинхронная операция через actor ThreadStore.
    /// Вызывается из UI через Task { await viewModel.selectThread(thread) }.
    ///
    /// ЧТО ПРОИСХОДИТ:
    /// 1. Устанавливаем activeThread
    /// 2. Загружаем настройки треда → activeThreadSettings
    /// 3. Загружаем историю сообщений → messages
    /// 4. Обновляем activeMemoryContext (threadId + projectIds)
    func selectThread(_ thread: ThreadMetadata) async {
        guard let store = threadStore else { return }

        self.activeThread = thread

        // Обновляем контекст памяти — теперь MemoryManager будет подмешивать
        // тредовую и проектную память для этого треда
        self.activeMemoryContext = MemoryContext(
            threadId: thread.id,
            projectIds: thread.projectIds
        )

        do {
            // Загружаем настройки треда (глубина контекста, токенный бюджет)
            let settings = try await store.loadSettings(forThreadId: thread.id)
            self.activeThreadSettings = settings

            // Загружаем историю сообщений треда из SwiftData
            let loaded = try await store.loadMessages(
                fromThreadId: thread.id,
                as: ChatMessage.self
            )

            // Устанавливаем историю БЕЗ вызова saveMessages через didSet.
            // ПОЧЕМУ: messages.didSet вызывает saveMessages() → ChatHistoryManager.
            // При загрузке треда мы НЕ хотим перезаписывать legacy-файл историей другого треда.
            // Используем прямое присвоение через обходной путь — сохраняем флаг.
            self.isLoadingThread = true
            self.messages = loaded
            self.isLoadingThread = false

            print("[ChappieViewModel] ✅ Тред '\(thread.title)' выбран (\(loaded.count) сообщений)")
        } catch {
            print("[ChappieViewModel] ⚠️ Ошибка загрузки треда '\(thread.title)': \(error)")
        }
    }

    /// Флаг: идёт загрузка треда — не сохранять в legacy ChatHistoryManager.
    ///
    /// ПОЧЕМУ НУЖЕН ЭТОТ ФЛАГ:
    /// messages.didSet вызывает saveMessages() при КАЖДОМ изменении массива.
    /// При загрузке истории треда из SwiftData мы не хотим перезаписывать
    /// legacy chat_history.json историей другого треда.
    /// Флаг позволяет saveMessages() пропустить сохранение в этот момент.
    private var isLoadingThread: Bool = false

    /// Создаёт новый тред и делает его активным.
    ///
    /// Вызывается по кнопке "Новый тред" в боковой панели.
    /// Новый тред начинается с пустой историей.
    func createNewThread() {
        guard let store = threadStore else { return }

        Task {
            do {
                let newId = try await store.createThread(title: "Новый тред")
                let refreshed = try await store.loadThreads()
                self.threads = refreshed

                if let newThread = refreshed.first(where: { $0.id == newId }) {
                    await selectThread(newThread)
                    // Сбрасываем историю для нового треда
                    self.isLoadingThread = true
                    self.messages = []
                    self.isLoadingThread = false
                }

                print("[ChappieViewModel] ✅ Создан новый тред")
            } catch {
                print("[ChappieViewModel] ⚠️ Ошибка создания треда: \(error)")
            }
        }
    }

    /// Удаляет тред. Если удаляется активный — переключаемся на первый оставшийся.
    ///
    /// ЗАЩИТА: Если удаляется последний тред — создаём новый автоматически.
    /// Пользователь не должен остаться без треда.
    func deleteThread(_ thread: ThreadMetadata) {
        guard let store = threadStore else { return }

        Task {
            do {
                try await store.deleteThread(id: thread.id)
                let refreshed = try await store.loadThreads()
                self.threads = refreshed

                // Если удалили активный тред — нужно выбрать другой
                if activeThread?.id == thread.id {
                    if let first = refreshed.first {
                        await selectThread(first)
                    } else {
                        // Тредов не осталось — создаём новый
                        let newId = try await store.createThread(title: "Новый тред")
                        let withNew = try await store.loadThreads()
                        self.threads = withNew
                        if let newThread = withNew.first(where: { $0.id == newId }) {
                            await selectThread(newThread)
                        }
                    }
                }

                print("[ChappieViewModel] 🗑 Тред '\(thread.title)' удалён")
            } catch {
                print("[ChappieViewModel] ⚠️ Ошибка удаления треда: \(error)")
            }
        }
    }

    /// Переименовывает тред.
    func renameThread(_ thread: ThreadMetadata, newTitle: String) {
        guard let store = threadStore else { return }

        Task {
            do {
                try await store.renameThread(id: thread.id, title: newTitle)
                let refreshed = try await store.loadThreads()
                self.threads = refreshed

                // Если переименовали активный — обновляем activeThread
                if activeThread?.id == thread.id,
                   let updated = refreshed.first(where: { $0.id == thread.id }) {
                    self.activeThread = updated
                }
            } catch {
                print("[ChappieViewModel] ⚠️ Ошибка переименования треда: \(error)")
            }
        }
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
    /// СОХРАНЕНИЕ В ТРЕД (IT-05):
    /// После добавления ответа в messages — сохраняем историю в активный тред через ThreadStore.
    /// Это дополняет существующее сохранение через ChatHistoryManager (legacy).
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
        let config = activeConfig
        let memoryContext = activeMemoryContext

        // Захватываем ID активного треда ДО входа в Task.
        // Нужно для сохранения истории в правильный тред после получения ответа.
        let activeThreadId = activeThread?.id

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

                // Сохраняем историю в активный тред SwiftData (IT-05).
                // Это дополнительное сохранение — legacy ChatHistoryManager
                // уже сохранил через messages.didSet.
                if let threadId = activeThreadId, let store = self.threadStore {
                    let currentMessages = self.messages
                    Task {
                        try? await store.saveMessages(currentMessages, toThreadId: threadId)
                        // Обновляем метаданные треда (updatedAt изменился)
                        let refreshed = try? await store.loadThreads()
                        if let refreshed {
                            await MainActor.run { self.threads = refreshed }
                        }
                    }
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

        // Очищаем историю и в активном треде SwiftData
        if let threadId = activeThread?.id, let store = threadStore {
            Task {
                try? await store.saveMessages([ChatMessage](), toThreadId: threadId)
            }
        }
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

    private func initializeServices(for url: URL) {
        let fs = FileSystemManager(workspaceURL: url)
        self.fileSystem = fs

        let mm = MemoryManager(workspaceURL: url)
        self.memoryManager = mm

        Task {
            await mm.initializeWorkspaceMemory()

            if let store = self.memoryStore {
                await mm.setMemoryStore(store)
            }
        }

        let socketPath = MCPHelperLauncher.shared.socketPath

        let ts = ToolExecutionService(fileSystem: fs, memoryManager: mm, socketPath: socketPath)
        self.toolService = ts

        self.orchestrator = AIOrchestrator(
            aiClient: aiClient,
            toolService: ts,
            fileSystem: fs,
            memoryManager: mm
        )
    }

    // MARK: - Миграция legacy-данных (IT-04)

    private func runMigrationIfNeeded(threadStore: ThreadStore, memoryStore: MemoryStore) async {
        let migrationService = MigrationService(
            threadStore: threadStore,
            memoryStore: memoryStore
        )

        let chatHistoryURL: URL
        if let workspaceURL = workspaceURL {
            chatHistoryURL = workspaceURL.appendingPathComponent("chat_history.json")
        } else {
            chatHistoryURL = ChatHistoryManager.shared.fileURL
        }

        let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let semanticURL = docsURL
            .appendingPathComponent("Chappie")
            .appendingPathComponent("semantic.json")

        let didMigrate = await migrationService.migrate(
            messageType: ChatMessage.self,
            chatHistoryURL: chatHistoryURL,
            semanticMemoryURL: semanticURL
        )

        if didMigrate {
            print("[ChappieViewModel] ✅ Миграция IT-04 выполнена успешно")
        }
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
        // Пропускаем сохранение в legacy-файл при загрузке треда из SwiftData.
        // Это предотвращает перезапись chat_history.json историей другого треда.
        guard !isLoadingThread else { return }
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
