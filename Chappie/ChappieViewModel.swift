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
// АРХИТЕКТУРА ЗАПУСКА ХЕЛПЕРА (MCPHelperLauncher):
// ПРОБЛЕМА: если запускать MCPHelperLauncher.shared.launch() без пути (из ChappieApp.onAppear),
// хелпер получает FileManager.currentDirectoryPath = "/" как воркспейс.
// Git не находит репозиторий, все команды падают.
//
// РЕШЕНИЕ: хелпер запускается ТОЛЬКО когда путь к воркспейсу известен:
//   а) loadWorkspaceWithSecurityScope() — восстановление при старте → launch(workspacePath:)
//   б) setWorkspace() — ручной выбор папки → restartWithWorkspace()
// ChappieApp.onAppear больше НЕ вызывает launch() — там путь ещё неизвестен.
//
// ИЗМЕНЕНИЕ (UX-SMOOTH-ANIMATION):
// Финальный переход "стриминг → сообщение" теперь анимирован:
// streamingText сбрасывается и messages обновляется в одном withAnimation блоке.
// Это устраняет резкий скачок когда Чаппи заканчивает печатать.
//
// ИЗМЕНЕНИЕ (UX-RUNNING-COST):
// Добавлено свойство runningCost: Double — накопительная стоимость текущего запроса.
// Нарастает с каждым внутренним API-вызовом оркестратора через callback onCostUpdate.
// Отображается в стриминговом пузыре в реальном времени — эффект "счётчика такси".
// Сбрасывается в 0 при начале нового запроса пользователя.

import SwiftUI
import ChappieCore

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
    ///
    /// ЗАЧЕМ ОТДЕЛЬНОЕ ВЫЧИСЛЯЕМОЕ СВОЙСТВО:
    /// 1. Фильтрация .toolCall: вызовы инструментов (их могут быть сотни за сессию)
    ///    не должны попадать в ленту — они переехали в строку состояния `currentToolCall`.
    /// 2. Лимит 30 сообщений: SwiftUI перерисовывает весь ForEach при ресайзе окна.
    ///    Ограничение количества элементов напрямую снижает нагрузку на рендер и
    ///    потребление памяти. 30 — достаточно для контекста разговора, не перегружает UI.
    /// 3. Хранилище (messages) при этом не трогаем — полная история пишется на диск.
    var visibleMessages: [ChatMessage] {
        let onlyMessages = messages.filter { msg in
            if case .message = msg { return true }
            return false
        }
        return Array(onlyMessages.suffix(30))
    }

    /// Флаг, показывающий, что ИИ сейчас размышляет (выполняет шаги оркестрации).
    var isThinking = false

    /// Накопленный текст стримингового ответа.
    ///
    /// ЗАЧЕМ ОТДЕЛЬНОЕ СВОЙСТВО:
    /// Пока Чаппи генерирует финальный ответ, токены приходят по одному.
    /// Добавлять каждый токен как отдельное .message в массив messages нельзя —
    /// это создало бы тысячи записей. Вместо этого мы накапливаем токены здесь,
    /// а UI отображает этот текст как специальный "живой" пузырь поверх ленты.
    /// Когда генерация завершается — streamingText сбрасывается, а полный текст
    /// добавляется в messages как обычное .message.
    var streamingText: String = ""

    /// Накопительная стоимость текущего запроса в рублях — нарастающий итог.
    ///
    /// ЗАЧЕМ:
    /// Оркестратор может выполнить N внутренних API-вызовов за один запрос пользователя
    /// (вызовы инструментов, промежуточные ответы, финальный ответ).
    /// Каждый такой вызов стоит денег. runningCost нарастает с каждым шагом через
    /// callback onCostUpdate, чтобы пользователь видел реальную стоимость прямо сейчас.
    /// Эффект "счётчика такси" — цена растёт на глазах во время работы Чаппи.
    ///
    /// Сбрасывается в 0 при начале нового запроса пользователя.
    /// После завершения — финальное значение сохраняется в .message как cost.
    var runningCost: Double = 0.0

    /// Текущий вызываемый инструмент — отображается в строке состояния.
    ///
    /// ЗАЧЕМ СТРОКА СОСТОЯНИЯ ВМЕСТО ЗАПИСЕЙ В ЛЕНТЕ:
    /// Раньше каждый вызов инструмента добавлял .toolCall в messages.
    /// За один сложный запрос Чаппи может вызвать 20-50 инструментов —
    /// это засоряло ленту и создавало огромный список для рендера.
    /// Теперь вместо этого мы просто обновляем одну строку: "🛠 read_file → ..."
    /// Пользователь видит что происходит прямо сейчас, без засорения истории.
    /// После завершения работы — сбрасывается в nil (строка состояния исчезает).
    var currentToolCall: String? = nil

    /// Текущий баланс пользователя в рублях (загружается из API AITunnel).
    var currentBalance: Double? {
        didSet { UserDefaults.standard.set(currentBalance, forKey: "savedBalance") }
    }

    // MARK: - Настройки активного треда (IT-02)

    /// Настройки активного треда — определяют глубину контекста и токенный бюджет.
    ///
    /// АРХИТЕКТУРНОЕ РЕШЕНИЕ (IT-02):
    /// Вместо глобального AppConfig.shared — каждый тред имеет свои ThreadSettings.
    /// ViewModel создаёт AppConfig из этих настроек и передаёт в AIOrchestrator.process().
    ///
    /// ДЕФОЛТ: ThreadSettings() — 20 сообщений, 10,000 токенов.
    /// Заполняется из активного треда в IT-05 (UI боковой панели).
    /// До IT-05 — используется дефолт.
    var activeThreadSettings: ThreadSettings = ThreadSettings()

    /// Создаёт AppConfig из настроек активного треда.
    ///
    /// Вычисляемое свойство — всегда актуально при изменении activeThreadSettings.
    /// Используется в send() при вызове orchestrator.process().
    private var activeConfig: AppConfig {
        AppConfig(settings: activeThreadSettings)
    }

    // MARK: - Зависимости (Сервисы)

    private var fileSystem: FileSystemManager?
    private var memoryManager: MemoryManager?
    private var toolService: ToolExecutionService?

    /// Клиент API — хранится как var, потому что может быть пересоздан при смене ключа.
    private var aiClient: AITunnelClient

    private var orchestrator: AIOrchestrator?

    /// Менеджер истории чата, привязанный к текущему воркспейсу.
    private var chatHistoryManager: ChatHistoryManager

    // MARK: - Инициализация

    public init() {
        let savedKey = SettingsManager.shared.apiKey
        self.aiClient = AITunnelClient(apiKey: savedKey)
        self.chatHistoryManager = ChatHistoryManager.shared

        loadMessages()

        if let savedBalance = UserDefaults.standard.object(forKey: "savedBalance") as? Double {
            self.currentBalance = savedBalance
        }

        // ВАЖНО: loadWorkspaceWithSecurityScope() также запускает MCPHelperLauncher
        // с правильным путём к воркспейсу (если он был сохранён ранее).
        // Это единственное место старта хелпера при восстановлении сессии.
        loadWorkspaceWithSecurityScope()
    }

    // MARK: - Управление API-ключом

    /// Обновляет API-ключ и пересоздаёт AITunnelClient с новым ключом.
    func updateApiKey(_ newKey: String) {
        self.aiClient = AITunnelClient(apiKey: newKey)

        if let ts = toolService, let fs = fileSystem {
            self.orchestrator = AIOrchestrator(aiClient: aiClient, toolService: ts, fileSystem: fs)
        }

        messages.append(.message(isUser: false, text: "✅ API-ключ обновлён. Готов к работе!"))
    }

    // MARK: - Управление воркспейсом

    /// Подключает новую папку проекта к приложению Chappie.
    func setWorkspace(_ url: URL) {
        workspaceURL = url
        initializeServices(for: url)
        chatHistoryManager = ChatHistoryManager(workspaceURL: url)
        loadMessages()
        saveWorkspaceWithSecurityScope(url)

        // Перезапускаем хелпер ChappieMCP с новым воркспейсом.
        // Хелпер использует воркспейс как рабочий каталог для git и xcodebuild.
        MCPHelperLauncher.shared.restartWithWorkspace(url)

        if messages.isEmpty {
            messages.append(.message(isUser: false, text: "Проект подключен. Я готов к работе!"))
        }
    }

    // MARK: - Отправка сообщений и оркестрация

    /// Отправляет запрос пользователя в ИИ-оркестратор и запускает многошаговый цикл.
    ///
    /// КЛЮЧЕВОЕ РЕШЕНИЕ — КТО СТРОИТ КОНТЕКСТНОЕ ОКНО:
    /// ViewModel вызывает `buildRawNetworkHistory()` — это ТОЛЬКО конвертация
    /// ChatMessage → AIMessage без какого-либо сжатия или обрезки.
    /// AIOrchestrator.process() получает сырую историю и сам применяет
    /// buildContextWindow() с параметрами из activeConfig (настройки треда).
    ///
    /// ПЕРЕДАЧА КОНФИГА (IT-02):
    /// В process() передаётся activeConfig — AppConfig созданный из activeThreadSettings.
    /// Это позволяет каждому треду иметь свою глубину контекста.
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

        // Сбрасываем накопительную стоимость для нового запроса.
        // Пользователь должен видеть стоимость именно текущего запроса, а не сессии целиком.
        runningCost = 0.0

        // Конвертируем историю в сетевой формат БЕЗ сжатия.
        // Сжатие и токенное окно — ответственность AIOrchestrator.
        let networkHistory = buildRawNetworkHistory()

        // Захватываем конфиг активного треда ДО входа в Task.
        // Это необходимо для Swift 6 Sendable: Task захватывает значение (struct),
        // а не ссылку на @MainActor self. Struct AppConfig — Sendable, безопасно.
        let config = activeConfig

        Task {
            do {
                let result = try await orchestrator.process(
                    prompt: prompt,
                    history: networkHistory,
                    config: config,
                    onToolCall: { toolName, targetPath in
                        Task { @MainActor in
                            if targetPath.isEmpty {
                                self.currentToolCall = toolName
                            } else {
                                // Показываем только последние 2 компонента пути для краткости
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
                        // НАКОПИТЕЛЬНАЯ СТОИМОСТЬ:
                        // Каждый раз получаем нарастающий итог от оркестратора.
                        // Обновляем runningCost на главном потоке — SwiftUI перерисует пузырь.
                        // Анимация числа (.animation на Text) создаёт плавный эффект счётчика.
                        Task { @MainActor in
                            self.runningCost = cumulativeCost
                        }
                    }
                )

                // Разбираем ответ: извлекаем summary и очищаем текст от тега.
                let rawResponse = self.cleanAIResponse(result.finalResponse)
                let (displayText, summary) = self.extractAndCleanSummary(from: rawResponse)

                // Финальная стоимость запроса — сохраняем в сообщение.
                let finalCost = result.totalCost

                // ПЛАВНЫЙ ФИНАЛЬНЫЙ ПЕРЕХОД:
                // Проблема без анимации: streamingText сбрасывается в "" — стриминговый пузырь
                // исчезает. Затем messages обновляется — новое сообщение появляется.
                // Это два отдельных события, между которыми SwiftUI рендерит "пустоту" — рывок.
                //
                // Решение: оборачиваем ОБА изменения в один withAnimation блок.
                // SwiftUI видит их как единую транзакцию и анимирует переход плавно:
                // стриминговый пузырь плавно уходит, финальное сообщение плавно въезжает.
                // spring(response:0.5) чуть медленнее чем обычный spring(0.4) — финальный
                // ответ "приземляется" мягче, без торопливости.
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
                // При ошибке тоже анимируем — сообщение об ошибке должно появляться плавно,
                // а не выпрыгивать резко после исчезновения стримингового пузыря.
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    self.streamingText = ""
                    self.currentToolCall = nil
                    self.messages.append(.message(isUser: false, text: "Упс, ошибка: \(error.localizedDescription)"))
                }
            }

            // isThinking сбрасываем отдельно — его анимация уже настроена в ContentView
            // через .animation(.easeInOut, value: viewModel.isThinking).
            // Если включить в withAnimation выше — spring перебьёт easeInOut для StatusBarView.
            isThinking = false
        }
    }

    // MARK: - Управление историей

    /// Очищает историю чата текущего воркспейса.
    func clearMessages() {
        messages = []
    }

    /// Полная очистка контекста с приветственным сообщением.
    func clearHistory() {
        messages.removeAll()
        messages.append(.message(isUser: false, text: "Память очищена. Я забыл всё, что мы обсуждали до этого момента. Готов начать с чистого листа!"))
    }

    // MARK: - Конвертация истории в сетевой формат (БЕЗ сжатия)

    /// Конвертирует UI-историю в сетевой формат AIMessage БЕЗ какого-либо сжатия.
    ///
    /// ОТВЕТСТВЕННОСТЬ ЭТОГО МЕТОДА — ТОЛЬКО КОНВЕРТАЦИЯ ТИПОВ:
    /// ChatMessage (UI-тип) → AIMessage (сетевой тип)
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

    /// Извлекает тег <summary> из ответа Чаппи и возвращает (чистый текст, summary).
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
    /// КЛЮЧЕВОЙ МОМЕНТ — ПЕРЕДАЧА socketPath:
    /// MCPHelperLauncher.shared.socketPath — это путь к Unix Domain Socket (/tmp/com.chappie.mcp.sock).
    /// Этот путь передаётся в ToolExecutionService, который передаёт его в MCPToolBridge.
    /// MCPToolBridge использует его для POSIX connect() к ChappieMCP серверу.
    ///
    /// Зачем передавать через DI, а не хардкодить в MCPToolBridge:
    /// MCPHelperLauncher — единственный источник истины о пути сокета.
    /// Это позволяет менять путь централизованно без правок в нескольких местах.
    private func initializeServices(for url: URL) {
        let fs = FileSystemManager(workspaceURL: url)
        self.fileSystem = fs

        let mm = MemoryManager(workspaceURL: url)
        self.memoryManager = mm

        Task {
            await mm.initializeWorkspaceMemory()
        }

        // Получаем socketPath от лаунчера — он является единственным источником истины
        let socketPath = MCPHelperLauncher.shared.socketPath

        let ts = ToolExecutionService(fileSystem: fs, memoryManager: mm, socketPath: socketPath)
        self.toolService = ts

        self.orchestrator = AIOrchestrator(aiClient: aiClient, toolService: ts, fileSystem: fs)
    }

    // MARK: - Очистка текста ответа

    /// Удаляет технические теги размышлений из финального ответа ИИ.
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

    /// Восстанавливает воркспейс из сохранённого Security-Scoped Bookmark.
    ///
    /// КЛЮЧЕВОЕ: этот метод также запускает MCPHelperLauncher с правильным путём.
    /// Это единственное место, где хелпер стартует при восстановлении сессии.
    ///
    /// ПОЧЕМУ ЗДЕСЬ, А НЕ В ChappieApp.onAppear:
    /// onAppear вызывается до восстановления воркспейса — путь ещё неизвестен.
    /// Если запустить хелпер без пути, он получит "/" как рабочий каталог,
    /// и все git/build команды упадут с "not a git repository".
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

            // Запускаем хелпер с правильным путём к воркспейсу.
            // Именно здесь — потому что путь уже известен и проверен.
            MCPHelperLauncher.shared.launch(workspacePath: url.path)

        } else {
            // Fallback: пробуем без security scope (sandbox удалён из проекта)
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

                // Запускаем хелпер даже в fallback-режиме — путь известен
                MCPHelperLauncher.shared.launch(workspacePath: url.path)
            }
        }
    }
}
