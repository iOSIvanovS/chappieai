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
// ПАРАМЕТРЫ — ОДИН ИСТОЧНИК ИСТИНЫ:
// Все параметры (tokenBudget, recentFullMessages, summaryThreshold) живут ТОЛЬКО в AppConfig.
// ViewModel и Orchestrator читают их оттуда. Никаких дублирующих констант.
//
// ИЗМЕНЕНИЕ (Этап 6 — ТД-6):
// Тип ChatMessage переехал в Models/ChatMessage.swift и стал enum.
// ViewModel больше не создаёт ChatMessage(isUser: false, text: "🛠 Выполняю: ...")  —
// вместо этого используется семантически корректный .toolCall(toolName:targetPath:).
// Фильтрация истории для API теперь опирается на типизированный кейс, а не на
// хрупкую проверку строки по содержимому (hasPrefix("🛠")).
//
// ИЗМЕНЕНИЕ (ТД-7 — Стриминг):
// Добавлено свойство `streamingText: String` — накапливает токены финального ответа
// по мере их поступления из SSE-потока. UI отображает его как "живой" пузырь.
// После завершения стриминга streamingText сбрасывается в "" и добавляется
// полноценное .message в историю (с cost и сохранением на диск).
//
// ИЗМЕНЕНИЕ (ТД-UX-PERF — Оптимизация производительности UI):
// `visibleMessages` — вычисляемое свойство, которое отдаёт в UI только последние
// 30 текстовых сообщений (.message). .toolCall в ленту не попадают вообще.
// `currentToolCall` — строка с именем текущего вызываемого инструмента.
//
// ИЗМЕНЕНИЕ (ТД-COST-SUMMARY — Self-Summary):
// Каждый ответ Чаппи содержит тег <summary>...</summary> в конце.
// Метод `extractAndCleanSummary()` извлекает его и возвращает отдельно от основного текста.
// Полный текст показывается пользователю, summary сохраняется в ChatMessage.summary.

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
    /// buildContextWindow() с параметрами из AppConfig.
    /// Это единственный источник истины для логики сжатия.
    ///
    /// СТРИМИНГ:
    /// Передаём в orchestrator.process() коллбэк onToken, который вызывается
    /// для каждого нового токена финального ответа. Токены аппендятся к streamingText
    /// на @MainActor — SwiftUI перерисовывает "живой" пузырь при каждом изменении.
    ///
    /// SELF-SUMMARY:
    /// После завершения оркестратора вызываем `extractAndCleanSummary()` —
    /// он разделяет полный ответ на (displayText, summary). displayText показываем
    /// пользователю, summary сохраняем в ChatMessage для будущей экономии токенов
    /// в buildContextWindow() оркестратора.
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

        // Конвертируем историю в сетевой формат БЕЗ сжатия.
        // Сжатие и токенное окно — ответственность AIOrchestrator.
        let networkHistory = buildRawNetworkHistory()

        Task {
            do {
                let result = try await orchestrator.process(
                    prompt: prompt,
                    history: networkHistory,
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
                    }
                )

                // Разбираем ответ: извлекаем summary и очищаем текст от тега.
                // cleanAIResponse убирает технические теги размышлений,
                // extractAndCleanSummary — разделяет <summary> от основного текста.
                let rawResponse = self.cleanAIResponse(result.finalResponse)
                let (displayText, summary) = self.extractAndCleanSummary(from: rawResponse)

                self.streamingText = ""
                self.currentToolCall = nil

                // Сохраняем сообщение с summary — он будет использован
                // в AIOrchestrator.compressMessage() для экономии токенов
                self.messages.append(.message(
                    isUser: false,
                    text: displayText,
                    cost: result.totalCost,
                    summary: summary
                ))

                if let newBalance = result.newBalance {
                    self.currentBalance = newBalance
                }
            } catch {
                self.streamingText = ""
                self.currentToolCall = nil
                self.messages.append(.message(isUser: false, text: "Упс, ошибка: \(error.localizedDescription)"))
            }

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
    ///
    /// ЧТО ЭТОТ МЕТОД НЕ ДЕЛАЕТ (и не должен делать):
    /// - НЕ обрезает историю по количеству
    /// - НЕ применяет токенный бюджет
    /// - НЕ заменяет длинные ответы на summary
    /// - НЕ удаляет блоки кода
    ///
    /// ПОЧЕМУ:
    /// Вся логика сжатия живёт в AIOrchestrator.buildContextWindow().
    /// Дублирование этой логики здесь приводило к двойному сжатию и
    /// рассинхронизации параметров (разные tokenBudget, разные recentFullMessages).
    ///
    /// Оркестратор получает сырую историю и сам решает что оставить,
    /// используя AppConfig как единственный источник истины для параметров.
    ///
    /// ИСКЛЮЧЕНИЯ (фильтруем):
    /// - .toolCall записи — модели не нужны логи вызовов инструментов
    /// - Системные сообщения ("Проект подключен", "Память очищена") — технический мусор
    private func buildRawNetworkHistory() -> [AIMessage] {
        return messages.compactMap { msg -> AIMessage? in
            // Пропускаем записи о вызовах инструментов — они не часть диалога
            guard case .message(_, let isUser, let text, _, let summary) = msg else {
                return nil
            }

            // Фильтруем системные/технические сообщения — они не несут контекста для модели
            let isSystemMessage = text.contains("Проект подключен")
                || text.contains("Память очищена")
                || text.contains("API-ключ обновлён")
                || text.hasPrefix("⚠️ API-ключ")
                || text.hasPrefix("Ошибка:")
                || text.hasPrefix("Упс, ошибка:")

            if isSystemMessage { return nil }

            // Передаём оба варианта текста — оркестратор сам выберет что использовать.
            // Если есть summary и текст длинный — оркестратор возьмёт summary.
            // Если summary нет или текст короткий — оркестратор возьмёт полный текст.
            //
            // ВАЖНО: Мы передаём полный text (не stripCodeBlocks!).
            // Оркестратор сам решает нужно ли убирать блоки кода.
            // Это позволяет централизовать всю логику сжатия в одном месте.
            let role = isUser ? "user" : "assistant"

            // Для ответов Чаппи передаём оба варианта через специальный формат:
            // content = полный текст, summary хранится в ChatMessage и используется
            // в AIOrchestrator.compressMessage() через extractSummary()
            //
            // Хитрость: мы встраиваем summary обратно в текст как тег <summary>,
            // чтобы оркестратор мог его извлечь через extractSummary().
            // Это позволяет не менять сигнатуру AIMessage.
            if !isUser, let summary = summary {
                // Встраиваем summary в конец текста — оркестратор его извлечёт
                let textWithSummary = text + "\n<summary>\(summary)</summary>"
                return AIMessage(role: role, content: textWithSummary)
            }

            return AIMessage(role: role, content: text)
        }
    }

    // MARK: - Парсинг Self-Summary

    /// Извлекает тег <summary> из ответа Чаппи и возвращает (чистый текст, summary).
    ///
    /// ФОРМАТ ТЕГА:
    /// Оркестратор требует от модели завершать каждый ответ тегом:
    ///   <summary>Краткое резюме действий.</summary>
    ///
    /// Этот метод:
    /// 1. Ищет последнее вхождение <summary>...</summary> в тексте.
    /// 2. Извлекает содержимое тега как summary.
    /// 3. Возвращает текст БЕЗ тега (для показа пользователю) и сам summary.
    ///
    /// ПОЧЕМУ ПОСЛЕДНЕЕ ВХОЖДЕНИЕ:
    /// Теоретически в ответе может быть несколько тегов (если модель упомянула
    /// пример тега в объяснении). Нас интересует только финальный summary.
    ///
    /// FALLBACK:
    /// Если тег не найден (модель нарушила правило) — summary == nil,
    /// полный текст используется как есть. Система не ломается, просто
    /// для этого сообщения не будет экономии токенов в будущем.
    private func extractAndCleanSummary(from text: String) -> (displayText: String, summary: String?) {
        // Регулярное выражение: ищем <summary>любой текст</summary>
        // .dotMatchesLineSeparators — summary может быть многострочным
        guard let regex = try? NSRegularExpression(
            pattern: "<summary>(.*?)</summary>",
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else {
            return (text, nil)
        }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        // Берём последнее совпадение — финальный summary
        guard let lastMatch = matches.last,
              let summaryRange = Range(lastMatch.range(at: 1), in: text),
              let fullMatchRange = Range(lastMatch.range, in: text) else {
            return (text, nil)
        }

        let summary = String(text[summaryRange]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Убираем тег из текста для отображения пользователю
        var displayText = text
        displayText.removeSubrange(fullMatchRange)
        displayText = displayText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Если после удаления тега текст пустой — значит ответ состоял только из summary.
        // Это странно, но не критично — показываем summary как текст.
        let finalDisplayText = displayText.isEmpty ? summary : displayText

        return (finalDisplayText, summary.isEmpty ? nil : summary)
    }

    // MARK: - Приватные методы инициализации сервисов

    /// Создаёт и связывает весь стек сервисов для указанного воркспейса.
    ///
    /// ЗАЧЕМ ОТДЕЛЬНЫЙ МЕТОД:
    /// Инициализация сервисов нужна в двух местах: setWorkspace() и loadWorkspaceWithSecurityScope().
    /// Вынос в отдельный метод устраняет дублирование — любое изменение стека сервисов
    /// нужно делать только здесь.
    private func initializeServices(for url: URL) {
        let fs = FileSystemManager(workspaceURL: url)
        self.fileSystem = fs

        let mm = MemoryManager(workspaceURL: url)
        self.memoryManager = mm

        Task {
            await mm.initializeWorkspaceMemory()
        }

        let ts = ToolExecutionService(fileSystem: fs, memoryManager: mm)
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
            // Миграция из старого хранилища UserDefaults
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

        } else {
            // Fallback без security scope (для разработки без sandbox)
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
