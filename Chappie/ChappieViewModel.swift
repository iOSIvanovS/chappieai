// ChappieViewModel.swift
// Chappie
//
// Главная ViewModel приложения Chappie.
// Управляет состоянием интерфейса, хранит историю сообщений, инициализирует сервисы
// и координирует работу ИИ-оркестратора.
//
// IT-09: syncActiveMemoryContext() теперь также вызывает ts.setProjectSettings()
// чтобы ToolExecutionService знал настройки каждого проекта для проверки прав.

import SwiftUI
import ChappieCore
import SwiftData

@Observable
@MainActor
final class ChappieViewModel {

    // MARK: - Свойства состояния

    var workspaceURL: URL?

    var messages: [ChatMessage] = [] {
        didSet { saveMessages() }
    }

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

    var currentBalance: Double? {
        didSet { UserDefaults.standard.set(currentBalance, forKey: "savedBalance") }
    }

    // MARK: - Система тредов (IT-05)

    var threads: [ThreadMetadata] = []
    var activeThread: ThreadMetadata? = nil

    // MARK: - Проекты в треде (IT-06)

    var activeProjects: [ProjectMetadata] = []

    // MARK: - Настройки активного треда (IT-02)

    var activeThreadSettings: ThreadSettings = ThreadSettings()

    private var activeConfig: AppConfig {
        AppConfig(settings: activeThreadSettings)
    }

    // MARK: - Контекст памяти для system prompt (IT-03, IT-05, IT-08, IT-09)

    var activeMemoryContext: MemoryContext = .empty

    // MARK: - Зависимости (Сервисы)

    private var fileSystem: FileSystemManager?
    private var memoryManager: MemoryManager?
    private var toolService: ToolExecutionService?

    private var aiClient: AITunnelClient
    private var orchestrator: AIOrchestrator?
    private var chatHistoryManager: ChatHistoryManager

    // MARK: - SwiftData

    private var modelContainer: ModelContainer?
    private var memoryStore: MemoryStore?
    private var threadStore: ThreadStore?
    private var projectStore: ProjectStore?

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

    // MARK: - Подключение SwiftData

    func setModelContainer(_ container: ModelContainer) {
        guard self.modelContainer == nil else { return }

        self.modelContainer = container

        let store = MemoryStore(modelContainer: container)
        self.memoryStore = store

        let tStore = ThreadStore(modelContainer: container)
        self.threadStore = tStore

        let pStore = ProjectStore(modelContainer: container)
        self.projectStore = pStore

        if let mm = memoryManager {
            Task {
                await mm.setMemoryStore(store)
            }
        }

        print("[ChappieViewModel] ✅ ModelContainer подключён: MemoryStore, ThreadStore, ProjectStore созданы")

        if let ts = toolService {
            registerProjectToolHandlers(toolService: ts, projectStore: pStore, threadStore: tStore)
        }

        Task {
            await runMigrationIfNeeded(threadStore: tStore, memoryStore: store)
            await loadThreadsAndSelectActive(from: tStore)
        }
    }

    // MARK: - Регистрация обработчиков инструментов проектов (IT-07)

    private func registerProjectToolHandlers(
        toolService ts: ToolExecutionService,
        projectStore pStore: ProjectStore,
        threadStore tStore: ThreadStore
    ) {
        Task {
            await ts.registerProjectHandlers(

                addProject: { [weak self] displayName in
                    return await withCheckedContinuation { continuation in
                        Task { @MainActor [weak self] in
                            guard let self else {
                                continuation.resume(returning: "Ошибка: ViewModel освобождена.")
                                return
                            }
                            let activeThread = self.activeThread
                            let result = await ChappieViewModel.performAddProjectByName(
                                displayName: displayName,
                                projectStore: pStore,
                                threadStore: tStore,
                                activeThread: activeThread,
                                onUpdate: { [weak self] updatedThread in
                                    Task { @MainActor [weak self] in
                                        await self?.reloadAfterProjectChange(
                                            updatedThread: updatedThread,
                                            projectStore: pStore,
                                            threadStore: tStore
                                        )
                                    }
                                }
                            )
                            continuation.resume(returning: result)
                        }
                    }
                },

                removeProject: { [weak self] displayName in
                    return await withCheckedContinuation { continuation in
                        Task { @MainActor [weak self] in
                            guard let self else {
                                continuation.resume(returning: "Ошибка: ViewModel освобождена.")
                                return
                            }
                            let activeThread = self.activeThread
                            let activeProjects = self.activeProjects
                            let result = await ChappieViewModel.performRemoveProjectByName(
                                displayName: displayName,
                                projectStore: pStore,
                                threadStore: tStore,
                                activeThread: activeThread,
                                activeProjects: activeProjects,
                                onUpdate: { [weak self] updatedThread in
                                    Task { @MainActor [weak self] in
                                        await self?.reloadAfterProjectChange(
                                            updatedThread: updatedThread,
                                            projectStore: pStore,
                                            threadStore: tStore
                                        )
                                    }
                                }
                            )
                            continuation.resume(returning: result)
                        }
                    }
                },

                listProjects: { [weak self] in
                    return await withCheckedContinuation { continuation in
                        Task { @MainActor [weak self] in
                            guard let self else {
                                continuation.resume(returning: "Ошибка: ViewModel освобождена.")
                                return
                            }
                            let names = self.activeProjects.map { $0.displayName }
                            if names.isEmpty {
                                continuation.resume(returning: "В текущем треде нет привязанных проектов.")
                            } else {
                                let list = names.enumerated()
                                    .map { "\($0.offset + 1). \($0.element)" }
                                    .joined(separator: "\n")
                                continuation.resume(returning: "Проекты в текущем треде:\n\(list)")
                            }
                        }
                    }
                }
            )
            print("[ChappieViewModel] ✅ Обработчики инструментов проектов зарегистрированы в ToolExecutionService")
        }
    }

    private static func performAddProjectByName(
        displayName: String,
        projectStore: ProjectStore,
        threadStore: ThreadStore,
        activeThread: ThreadMetadata?,
        onUpdate: @escaping @Sendable (ThreadMetadata) -> Void
    ) async -> String {
        guard let thread = activeThread else {
            return "Ошибка: Нет активного треда. Выберите тред перед добавлением проекта."
        }

        do {
            let allProjects = try await projectStore.loadProjects()
            let threadProjects = try await projectStore.loadProjects(ids: thread.projectIds)

            if threadProjects.contains(where: { $0.displayName == displayName }) {
                return "Проект '\(displayName)' уже добавлен в текущий тред."
            }

            let projectId: UUID
            if let existing = allProjects.first(where: { $0.displayName == displayName }) {
                projectId = existing.id
            } else {
                projectId = try await projectStore.addProject(
                    displayName: displayName,
                    bookmarkData: Data()
                )
            }

            var updatedIds = thread.projectIds
            updatedIds.append(projectId)
            try await threadStore.updateProjectBindings(updatedIds, forThreadId: thread.id)

            let refreshed = try await threadStore.loadThreads()
            if let updatedThread = refreshed.first(where: { $0.id == thread.id }) {
                onUpdate(updatedThread)
            }

            return "✅ Проект '\(displayName)' добавлен в текущий тред."
        } catch {
            return "Ошибка при добавлении проекта '\(displayName)': \(error.localizedDescription)"
        }
    }

    private static func performRemoveProjectByName(
        displayName: String,
        projectStore: ProjectStore,
        threadStore: ThreadStore,
        activeThread: ThreadMetadata?,
        activeProjects: [ProjectMetadata],
        onUpdate: @escaping @Sendable (ThreadMetadata) -> Void
    ) async -> String {
        guard let thread = activeThread else {
            return "Ошибка: Нет активного треда."
        }

        guard let project = activeProjects.first(where: { $0.displayName == displayName }) else {
            return "Проект '\(displayName)' не найден в текущем треде. Используй list_thread_projects чтобы увидеть список."
        }

        do {
            var updatedIds = thread.projectIds
            updatedIds.removeAll { $0 == project.id }
            try await threadStore.updateProjectBindings(updatedIds, forThreadId: thread.id)

            let refreshed = try await threadStore.loadThreads()
            if let updatedThread = refreshed.first(where: { $0.id == thread.id }) {
                onUpdate(updatedThread)
            }

            return "✅ Проект '\(displayName)' убран из текущего треда."
        } catch {
            return "Ошибка при удалении проекта '\(displayName)': \(error.localizedDescription)"
        }
    }

    private func reloadAfterProjectChange(
        updatedThread: ThreadMetadata,
        projectStore: ProjectStore,
        threadStore: ThreadStore
    ) async {
        do {
            let refreshed = try await threadStore.loadThreads()
            self.threads = refreshed

            if activeThread?.id == updatedThread.id {
                self.activeThread = updatedThread
                await loadProjectsForThread(updatedThread)
                buildAndSyncMemoryContext()
                await syncActiveMemoryContext()
            }
        } catch {
            print("[ChappieViewModel] ⚠️ Ошибка обновления после изменения проектов: \(error)")
        }
    }

    // MARK: - Сборка и синхронизация контекста памяти (IT-08, IT-09)

    /// Собирает MemoryContext с именами и настройками проектов.
    /// IT-09: включает settings из ProjectMetadata для блока прав в system prompt.
    private func buildAndSyncMemoryContext() {
        let projectInfos = activeProjects.map { project in
            MemoryContext.ProjectInfo(
                id: project.id,
                name: project.displayName,
                settings: project.settings
            )
        }

        self.activeMemoryContext = MemoryContext(
            threadId: activeThread?.id,
            projectInfos: projectInfos
        )
    }

    /// Синхронизирует ActiveMemoryContext и ProjectSettings в ToolExecutionService.
    ///
    /// IT-09: Дополнительно вызывает setProjectSettings() чтобы ToolExecutionService
    /// знал настройки каждого проекта для проверки прав при выполнении инструментов.
    /// Вызывается при любом изменении проектов или треда.
    private func syncActiveMemoryContext() async {
        guard let ts = toolService else { return }

        let projectInfos = activeProjects.map { project in
            ActiveMemoryContext.ProjectInfo(id: project.id, name: project.displayName)
        }

        let context = ActiveMemoryContext(
            threadId: activeThread?.id,
            projects: projectInfos
        )

        await ts.setActiveMemoryContext(context)

        // IT-09: передаём настройки проектов для проверки прав инструментов
        let settingsMap = Dictionary(
            uniqueKeysWithValues: activeProjects.map { ($0.id, $0.settings) }
        )
        await ts.setProjectSettings(settingsMap)
    }

    // MARK: - Управление тредами (IT-05)

    private func loadThreadsAndSelectActive(from store: ThreadStore) async {
        do {
            let loaded = try await store.loadThreads()
            self.threads = loaded

            if loaded.isEmpty {
                let newId = try await store.createThread(title: "Новый тред")
                let refreshed = try await store.loadThreads()
                self.threads = refreshed
                if let newThread = refreshed.first(where: { $0.id == newId }) {
                    await selectThread(newThread)
                }
            } else if let current = activeThread,
                      let updated = loaded.first(where: { $0.id == current.id }) {
                self.activeThread = updated
                buildAndSyncMemoryContext()
            } else {
                await selectThread(loaded[0])
            }
        } catch {
            print("[ChappieViewModel] ⚠️ Ошибка загрузки тредов: \(error)")
        }
    }

    func selectThread(_ thread: ThreadMetadata) async {
        guard let store = threadStore else { return }

        self.activeThread = thread

        do {
            let settings = try await store.loadSettings(forThreadId: thread.id)
            self.activeThreadSettings = settings

            let loaded = try await store.loadMessages(
                fromThreadId: thread.id,
                as: ChatMessage.self
            )

            self.isLoadingThread = true
            self.messages = loaded
            self.isLoadingThread = false

            print("[ChappieViewModel] ✅ Тред '\(thread.title)' выбран (\(loaded.count) сообщений)")
        } catch {
            print("[ChappieViewModel] ⚠️ Ошибка загрузки треда '\(thread.title)': \(error)")
        }

        await loadProjectsForThread(thread)
        buildAndSyncMemoryContext()
        await syncActiveMemoryContext()
    }

    private var isLoadingThread: Bool = false

    func createNewThread() {
        guard let store = threadStore else { return }

        Task {
            do {
                let newId = try await store.createThread(title: "Новый тред")
                let refreshed = try await store.loadThreads()
                self.threads = refreshed

                if let newThread = refreshed.first(where: { $0.id == newId }) {
                    await selectThread(newThread)
                    self.isLoadingThread = true
                    self.messages = []
                    self.isLoadingThread = false
                    self.activeProjects = []
                    buildAndSyncMemoryContext()
                    await syncActiveMemoryContext()
                }

                print("[ChappieViewModel] ✅ Создан новый тред")
            } catch {
                print("[ChappieViewModel] ⚠️ Ошибка создания треда: \(error)")
            }
        }
    }

    func deleteThread(_ thread: ThreadMetadata) {
        guard let store = threadStore else { return }

        Task {
            do {
                try await store.deleteThread(id: thread.id)
                let refreshed = try await store.loadThreads()
                self.threads = refreshed

                if activeThread?.id == thread.id {
                    if let first = refreshed.first {
                        await selectThread(first)
                    } else {
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

    func renameThread(_ thread: ThreadMetadata, newTitle: String) {
        guard let store = threadStore else { return }

        Task {
            do {
                try await store.renameThread(id: thread.id, title: newTitle)
                let refreshed = try await store.loadThreads()
                self.threads = refreshed

                if activeThread?.id == thread.id,
                   let updated = refreshed.first(where: { $0.id == thread.id }) {
                    self.activeThread = updated
                }
            } catch {
                print("[ChappieViewModel] ⚠️ Ошибка переименования треда: \(error)")
            }
        }
    }

    // MARK: - Управление проектами в треде (IT-06)

    private func loadProjectsForThread(_ thread: ThreadMetadata) async {
        guard let pStore = projectStore else {
            self.activeProjects = []
            return
        }

        guard !thread.projectIds.isEmpty else {
            self.activeProjects = []
            return
        }

        do {
            let projects = try await pStore.loadProjects(ids: thread.projectIds)
            self.activeProjects = projects
            print("[ChappieViewModel] 📁 Загружено \(projects.count) проектов для треда '\(thread.title)'")
        } catch {
            print("[ChappieViewModel] ⚠️ Ошибка загрузки проектов треда: \(error)")
            self.activeProjects = []
        }
    }

    func addProject(url: URL) {
        guard let pStore = projectStore,
              let tStore = threadStore,
              let thread = activeThread else { return }

        Task {
            do {
                let bookmarkData: Data
                do {
                    bookmarkData = try url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                } catch {
                    bookmarkData = try url.bookmarkData(
                        options: [],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                }

                let displayName = url.lastPathComponent

                let alreadyAdded = activeProjects.contains { $0.displayName == displayName }
                guard !alreadyAdded else {
                    print("[ChappieViewModel] ℹ️ Проект '\(displayName)' уже добавлен в тред")
                    return
                }

                let projectId = try await pStore.addProject(
                    displayName: displayName,
                    bookmarkData: bookmarkData
                )

                var updatedIds = thread.projectIds
                updatedIds.append(projectId)
                try await tStore.updateProjectBindings(updatedIds, forThreadId: thread.id)

                let refreshed = try await tStore.loadThreads()
                self.threads = refreshed

                if let updatedThread = refreshed.first(where: { $0.id == thread.id }) {
                    self.activeThread = updatedThread
                    await loadProjectsForThread(updatedThread)
                    buildAndSyncMemoryContext()
                    await syncActiveMemoryContext()
                }

                print("[ChappieViewModel] ✅ Проект '\(displayName)' добавлен в тред '\(thread.title)'")
            } catch {
                print("[ChappieViewModel] ⚠️ Ошибка добавления проекта: \(error)")
            }
        }
    }

    func removeProject(id projectId: UUID) {
        guard let tStore = threadStore,
              let thread = activeThread else { return }

        Task {
            do {
                var updatedIds = thread.projectIds
                updatedIds.removeAll { $0 == projectId }
                try await tStore.updateProjectBindings(updatedIds, forThreadId: thread.id)

                let refreshed = try await tStore.loadThreads()
                self.threads = refreshed

                if let updatedThread = refreshed.first(where: { $0.id == thread.id }) {
                    self.activeThread = updatedThread
                    await loadProjectsForThread(updatedThread)
                    buildAndSyncMemoryContext()
                    await syncActiveMemoryContext()
                }

                print("[ChappieViewModel] 🗑 Проект убран из треда '\(thread.title)'")
            } catch {
                print("[ChappieViewModel] ⚠️ Ошибка удаления проекта из треда: \(error)")
            }
        }
    }

    // MARK: - IT-09: Обновление настроек проекта

    /// Сохраняет обновлённые настройки проекта и синхронизирует контекст памяти.
    /// Вызывается из ProjectSettingsSheet при нажатии "Сохранить".
    func updateProjectSettings(_ settings: ProjectSettings, forProjectId projectId: UUID) {
        guard let pStore = projectStore,
              let thread = activeThread else { return }

        Task {
            do {
                try await pStore.updateSettings(settings, forProjectId: projectId)
                await loadProjectsForThread(thread)
                buildAndSyncMemoryContext()
                await syncActiveMemoryContext()
                print("[ChappieViewModel] ✅ Настройки проекта обновлены (id: \(projectId))")
            } catch {
                print("[ChappieViewModel] ⚠️ Ошибка обновления настроек проекта: \(error)")
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

                if let threadId = activeThreadId, let store = self.threadStore {
                    let currentMessages = self.messages
                    Task {
                        try? await store.saveMessages(currentMessages, toThreadId: threadId)
                        let refreshed = try? await store.loadThreads()
                        if let refreshed {
                            await MainActor.run { self.threads = refreshed }
                        }
                    }
                }

            } catch is CancellationError {
                print("[ChappieViewModel] ℹ️ Запрос отменён (CancellationError) — тихое завершение")
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    self.streamingText = ""
                    self.currentToolCall = nil
                }

            } catch ChappieError.cancelled {
                print("[ChappieViewModel] ℹ️ Запрос отменён (URLError.cancelled) — тихое завершение")
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    self.streamingText = ""
                    self.currentToolCall = nil
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

        if let pStore = projectStore, let tStore = threadStore {
            registerProjectToolHandlers(toolService: ts, projectStore: pStore, threadStore: tStore)
        }

        Task {
            await syncActiveMemoryContext()
        }
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
