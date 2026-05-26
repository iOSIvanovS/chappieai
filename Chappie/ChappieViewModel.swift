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
// ТРЁХУРОВНЕВАЯ ПАМЯТЬ (IT-03, IT-08):
// MemoryStore (SwiftData) подключается к MemoryManager через setMemoryStore().
// AIOrchestrator.process() получает MemoryContext (threadId + projectInfos).
// Перед каждым запросом MemoryManager.buildSystemPrompt() автоматически подмешивает
// глобальную + проектную + тредовую память в system prompt.
//
// ТРЁХУРОВНЕВАЯ ПАМЯТЬ — UUID-BASED + ИМЕНА (IT-08 финал):
// MemoryContext теперь содержит projectInfos: [ProjectInfo] (UUID + имя каждого проекта).
// buildSystemPrompt() использует имена для заголовков: "📁 Память проекта: Chappie".
// ToolExecutionService работает с ActiveMemoryContext (threadId UUID + [ProjectInfo{id,name}]).
// syncActiveMemoryContext() собирает реальные UUID+имена из activeProjects и activeThread.
//
// СИСТЕМА ТРЕДОВ (IT-05):
// Каждый тред — это отдельная история сообщений в SwiftData.
// При выборе треда загружается его история из ThreadStore.
// При отправке сообщения — история сохраняется в активный тред.
// activeMemoryContext заполняется из активного треда (threadId + projectInfos).
// ChatHistoryManager продолжает работать параллельно как legacy-фолбэк.
//
// ПЛАШКИ ПРОЕКТОВ (IT-06):
// Каждый тред может иметь привязанные проекты.
// activeProjects — список ProjectMetadata для отображения в ProjectChipsView.
// При выборе треда загружаются его проекты из ProjectStore.
// addProject(url:) — создаёт/находит ProjectEntity, добавляет UUID в тред.
// removeProject(id:) — убирает UUID из треда (ProjectEntity не удаляется).
//
// ИНСТРУМЕНТЫ УПРАВЛЕНИЯ ПРОЕКТАМИ (IT-07):
// Чаппи может сам добавлять/удалять проекты в треде через инструменты:
//   add_project_to_thread(display_name:)
//   remove_project_from_thread(display_name:)
//   list_thread_projects()
// Реализовано через паттерн callback/closure: ViewModel регистрирует обработчики
// в ToolExecutionService через registerProjectHandlers() после создания ProjectStore.
// Обработчики работают по displayName (имени папки) — без NSOpenPanel (Чаппи не может открыть UI).
// Для add_project_to_thread — ищем существующий проект или создаём новый без bookmark.
//
// АРХИТЕКТУРНОЕ РЕШЕНИЕ — SENDABLE ЗАМЫКАНИЯ (IT-07):
// Замыкания @Sendable не могут захватить self (@MainActor) напрямую.
// Используем withCheckedContinuation + Task { @MainActor in } для безопасного доступа к self.
// Это позволяет выполнять операции на MainActor из @Sendable замыкания.
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
// ОБРАБОТКА ОТМЕНЫ ЗАПРОСА (FIX-CANCELLED):
// URLSession бросает URLError(.cancelled) когда Swift Task отменяется во время стриминга.
// AITunnelClient оборачивает это в ChappieError.cancelled.
// send() ловит CancellationError и ChappieError.cancelled ОТДЕЛЬНО от других ошибок —
// тихо завершает работу без показа "Упс, ошибка: cancelled" пользователю.
// Это нормальное поведение: пользователь нажал отправить повторно или View пересоздался.

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

    // MARK: - Проекты в треде (IT-06)

    /// Список проектов, привязанных к активному треду.
    ///
    /// Отображается в ProjectChipsView над лентой сообщений.
    /// Загружается из ProjectStore при выборе треда.
    /// Обновляется при addProject() и removeProject().
    var activeProjects: [ProjectMetadata] = []

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

    // MARK: - Контекст памяти для system prompt (IT-03, IT-05, IT-08 финал)

    /// Контекст треда для подмешивания трёхуровневой памяти в system prompt.
    ///
    /// АРХИТЕКТУРНОЕ РЕШЕНИЕ (IT-03 + IT-05 + IT-08 финал):
    /// MemoryContext содержит threadId и projectInfos (UUID + имя каждого проекта).
    /// Это всё что нужно MemoryManager для сборки полного system prompt с памятью.
    /// Имена проектов используются в заголовках блоков: "📁 Память проекта: Chappie".
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

    // MARK: - SwiftData (IT-03 + IT-04 + IT-05 + IT-06)

    /// Контейнер SwiftData — передаётся из ChappieApp через setModelContainer().
    private var modelContainer: ModelContainer?

    /// MemoryStore — SwiftData бэкенд для трёхуровневой памяти.
    private var memoryStore: MemoryStore?

    /// ThreadStore — SwiftData бэкенд для тредов.
    private var threadStore: ThreadStore?

    /// ProjectStore — SwiftData бэкенд для проектов (IT-06).
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

    // MARK: - Подключение SwiftData (IT-03 + IT-04 + IT-05 + IT-06 + IT-07)

    /// Подключает ModelContainer к ViewModel — вызывается из ContentView.onAppear.
    ///
    /// ЧТО ПРОИСХОДИТ:
    /// 1. Создаётся MemoryStore с переданным контейнером
    /// 2. Создаётся ThreadStore с переданным контейнером
    /// 3. Создаётся ProjectStore с переданным контейнером (IT-06)
    /// 4. MemoryStore подключается к MemoryManager через setMemoryStore()
    /// 5. После этого buildSystemPrompt() начинает читать из SwiftData
    /// 6. Запускается MigrationService — переносит legacy-данные в SwiftData (один раз)
    /// 7. После миграции — загружается список тредов (IT-05)
    /// 8. Регистрируются обработчики проектов в ToolExecutionService (IT-07)
    func setModelContainer(_ container: ModelContainer) {
        guard self.modelContainer == nil else { return } // Идемпотентность

        self.modelContainer = container

        let store = MemoryStore(modelContainer: container)
        self.memoryStore = store

        let tStore = ThreadStore(modelContainer: container)
        self.threadStore = tStore

        // IT-06: создаём ProjectStore
        let pStore = ProjectStore(modelContainer: container)
        self.projectStore = pStore

        if let mm = memoryManager {
            Task {
                await mm.setMemoryStore(store)
            }
        }

        print("[ChappieViewModel] ✅ ModelContainer подключён: MemoryStore, ThreadStore, ProjectStore созданы")

        // IT-07: регистрируем обработчики инструментов управления проектами в ToolExecutionService.
        // ПОЧЕМУ ЗДЕСЬ: регистрация возможна только после создания ProjectStore и ThreadStore.
        // ToolExecutionService уже создан (в initializeServices), поэтому регистрируем сейчас.
        if let ts = toolService {
            registerProjectToolHandlers(toolService: ts, projectStore: pStore, threadStore: tStore)
        }

        Task {
            await runMigrationIfNeeded(threadStore: tStore, memoryStore: store)
            // После миграции загружаем треды и выбираем активный
            await loadThreadsAndSelectActive(from: tStore)
        }
    }

    // MARK: - Регистрация обработчиков инструментов проектов (IT-07)

    /// Регистрирует callback-обработчики в ToolExecutionService для инструментов управления проектами.
    ///
    /// ПАТТЕРН CALLBACK/CLOSURE:
    /// ToolExecutionService живёт в ChappieCore и не знает о ProjectStore/ThreadStore напрямую.
    /// ViewModel регистрирует замыкания, которые вызываются когда Чаппи использует инструменты.
    ///
    /// АРХИТЕКТУРНОЕ РЕШЕНИЕ — SENDABLE + MainActor:
    /// Замыкания помечены @Sendable — нельзя захватить self (@MainActor) напрямую.
    /// Используем withCheckedContinuation + Task { @MainActor [weak self] in } для безопасного
    /// доступа к свойствам ViewModel (activeThread, activeProjects) из @Sendable замыкания.
    ///
    /// ПОЧЕМУ [weak self]:
    /// Замыкания хранятся в ToolExecutionService на время жизни сервиса.
    /// Слабая ссылка предотвращает retain-цикл: ViewModel → ToolExecutionService → замыкание → ViewModel.
    private func registerProjectToolHandlers(
        toolService ts: ToolExecutionService,
        projectStore pStore: ProjectStore,
        threadStore tStore: ThreadStore
    ) {
        Task {
            await ts.registerProjectHandlers(

                // ОБРАБОТЧИК: добавить проект по имени
                addProject: { [weak self] displayName in
                    // withCheckedContinuation позволяет "мостить" async-код с callback-based кодом.
                    // Нужен потому что мы должны вернуть String из @Sendable замыкания,
                    // но доступ к self требует MainActor.
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

                // ОБРАБОТЧИК: удалить проект по имени
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

                // ОБРАБОТЧИК: список проектов текущего треда
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

    /// Выполняет добавление проекта по имени — вызывается из callback обработчика.
    ///
    /// ПОЧЕМУ STATIC:
    /// Статический метод не захватывает self — безопасен для вызова из @Sendable замыкания.
    /// Принимает все нужные зависимости явными параметрами.
    ///
    /// ЛОГИКА ПОИСКА ПРОЕКТА:
    /// 1. Ищем существующий проект с таким displayName в ProjectStore
    /// 2. Если нашли — добавляем его UUID в тред
    /// 3. Если не нашли — создаём новый ProjectEntity без bookmark
    ///    (Чаппи не может открыть NSOpenPanel; bookmark добавит пользователь через UI)
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
            // Загружаем все существующие проекты для поиска по имени
            let allProjects = try await projectStore.loadProjects()
            // Загружаем проекты уже привязанные к треду для проверки дублей
            let threadProjects = try await projectStore.loadProjects(ids: thread.projectIds)

            // Проверяем дубликат
            if threadProjects.contains(where: { $0.displayName == displayName }) {
                return "Проект '\(displayName)' уже добавлен в текущий тред."
            }

            // Ищем существующий проект с таким именем (мог быть создан через UI)
            let projectId: UUID
            if let existing = allProjects.first(where: { $0.displayName == displayName }) {
                projectId = existing.id
                print("[ChappieViewModel] 📁 Найден существующий проект '\(displayName)' (id: \(existing.id))")
            } else {
                // Создаём новый проект без security-scoped bookmark.
                // ПОЧЕМУ БЕЗ BOOKMARK: Чаппи не может открыть NSOpenPanel.
                // Пустой Data() — bookmark будет добавлен пользователем через UI при необходимости.
                // Для целей памяти и контекста проекта bookmark не нужен.
                projectId = try await projectStore.addProject(
                    displayName: displayName,
                    bookmarkData: Data()
                )
                print("[ChappieViewModel] 📁 Создан новый проект '\(displayName)' без bookmark (id: \(projectId))")
            }

            // Атомарно обновляем привязки треда
            var updatedIds = thread.projectIds
            updatedIds.append(projectId)
            try await threadStore.updateProjectBindings(updatedIds, forThreadId: thread.id)

            // Загружаем обновлённые метаданные треда для передачи в onUpdate
            let refreshed = try await threadStore.loadThreads()
            if let updatedThread = refreshed.first(where: { $0.id == thread.id }) {
                onUpdate(updatedThread)
            }

            return "✅ Проект '\(displayName)' добавлен в текущий тред."
        } catch {
            return "Ошибка при добавлении проекта '\(displayName)': \(error.localizedDescription)"
        }
    }

    /// Выполняет удаление проекта из треда по имени.
    ///
    /// ПОЧЕМУ STATIC: аналогично performAddProjectByName — безопасен для @Sendable замыкания.
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

        // Ищем проект по имени в списке проектов активного треда
        guard let project = activeProjects.first(where: { $0.displayName == displayName }) else {
            return "Проект '\(displayName)' не найден в текущем треде. Используй list_thread_projects чтобы увидеть список."
        }

        do {
            // Убираем UUID из списка привязок треда
            var updatedIds = thread.projectIds
            updatedIds.removeAll { $0 == project.id }
            try await threadStore.updateProjectBindings(updatedIds, forThreadId: thread.id)

            // Загружаем обновлённые метаданные треда
            let refreshed = try await threadStore.loadThreads()
            if let updatedThread = refreshed.first(where: { $0.id == thread.id }) {
                onUpdate(updatedThread)
            }

            return "✅ Проект '\(displayName)' убран из текущего треда."
        } catch {
            return "Ошибка при удалении проекта '\(displayName)': \(error.localizedDescription)"
        }
    }

    /// Обновляет состояние ViewModel после изменения проектов в треде.
    ///
    /// Вызывается из callback-обработчиков после успешного add/remove.
    /// Обновляет threads, activeThread, activeMemoryContext и activeProjects.
    private func reloadAfterProjectChange(
        updatedThread: ThreadMetadata,
        projectStore: ProjectStore,
        threadStore: ThreadStore
    ) async {
        do {
            // Обновляем список тредов в боковой панели
            let refreshed = try await threadStore.loadThreads()
            self.threads = refreshed

            // Обновляем activeThread если это он изменился
            if activeThread?.id == updatedThread.id {
                self.activeThread = updatedThread

                // Перезагружаем список проектов для ProjectChipsView
                await loadProjectsForThread(updatedThread)

                // IT-08 финал: синхронизируем MemoryContext с именами проектов.
                // ПОЧЕМУ ПОСЛЕ loadProjectsForThread: нужен актуальный activeProjects с именами.
                buildAndSyncMemoryContext()

                // IT-08: синхронизируем ActiveMemoryContext в ToolExecutionService.
                // ПОЧЕМУ ЗДЕСЬ: после add/remove через инструменты Чаппи список проектов
                // изменился — нужно обновить контекст с реальными UUID в ToolExecutionService.
                await syncActiveMemoryContext()
            }
        } catch {
            print("[ChappieViewModel] ⚠️ Ошибка обновления после изменения проектов: \(error)")
        }
    }

    // MARK: - Сборка и синхронизация контекста памяти (IT-08 финал)

    /// Собирает MemoryContext с именами проектов и сохраняет в activeMemoryContext.
    ///
    /// ЗАЧЕМ ОТДЕЛЬНЫЙ МЕТОД (IT-08 финал):
    /// activeMemoryContext используется в process() → buildSystemPrompt().
    /// buildSystemPrompt() теперь использует имена проектов для заголовков блоков.
    /// Этот метод гарантирует что activeMemoryContext всегда содержит актуальные UUID+имена.
    ///
    /// КОГДА ВЫЗЫВАТЬ:
    /// - После selectThread() — загружены проекты нового треда
    /// - После addProject() / removeProject() — список изменился
    /// - После reloadAfterProjectChange() — Чаппи изменил проекты через инструменты
    private func buildAndSyncMemoryContext() {
        // Собираем ProjectInfo с UUID и именем из activeProjects (ProjectMetadata)
        let projectInfos = activeProjects.map { project in
            MemoryContext.ProjectInfo(id: project.id, name: project.displayName)
        }

        self.activeMemoryContext = MemoryContext(
            threadId: activeThread?.id,
            projectInfos: projectInfos
        )
    }

    // MARK: - Синхронизация ActiveMemoryContext в ToolExecutionService (IT-08)

    /// Синхронизирует полный ActiveMemoryContext (UUID треда + UUID+имя каждого проекта)
    /// в ToolExecutionService.
    ///
    /// ЗАЧЕМ (IT-08):
    /// ToolExecutionService.resolveScope() маппирует:
    ///   - scope="thread"       → UUID активного треда
    ///   - targetName="Chappie" → UUID проекта с именем "Chappie"
    /// Для этого ToolExecutionService должен знать реальные UUID, а не только имена.
    ///
    /// РАЗНИЦА С ПРЕДЫДУЩИМ ПОДХОДОМ:
    /// Старый метод syncProjectGuard() вызывал setActiveProjectNames([String]) —
    /// без UUID. Инструменты памяти получали заглушки UUID и не могли корректно
    /// маппировать targetName → scope.
    /// Новый метод syncActiveMemoryContext() передаёт полный ActiveMemoryContext
    /// с реальными UUID из ProjectMetadata и activeThread.
    ///
    /// КОГДА ВЫЗЫВАТЬ:
    /// - После selectThread() — загружены проекты нового треда
    /// - После addProject() / removeProject() — список изменился
    /// - После reloadAfterProjectChange() — Чаппи изменил проекты через инструменты
    private func syncActiveMemoryContext() async {
        guard let ts = toolService else { return }

        // Собираем ProjectInfo с реальными UUID из activeProjects (ProjectMetadata).
        // ProjectMetadata.id — это UUID из SwiftData ProjectEntity, тот же UUID
        // что хранится в MemoryEntity.scope для памяти этого проекта.
        let projectInfos = activeProjects.map { project in
            ActiveMemoryContext.ProjectInfo(id: project.id, name: project.displayName)
        }

        let context = ActiveMemoryContext(
            threadId: activeThread?.id,
            projects: projectInfos
        )

        await ts.setActiveMemoryContext(context)
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
                // Синхронизируем MemoryContext с именами проектов
                buildAndSyncMemoryContext()
            } else {
                // Выбираем первый тред (самый свежий)
                await selectThread(loaded[0])
            }
        } catch {
            print("[ChappieViewModel] ⚠️ Ошибка загрузки тредов: \(error)")
        }
    }

    /// Выбирает тред — загружает его историю, настройки и проекты.
    ///
    /// ПОЧЕМУ ASYNC:
    /// Загрузка сообщений из SwiftData — асинхронная операция через actor ThreadStore.
    /// Вызывается из UI через Task { await viewModel.selectThread(thread) }.
    ///
    /// ЧТО ПРОИСХОДИТ:
    /// 1. Устанавливаем activeThread
    /// 2. Загружаем настройки треда → activeThreadSettings
    /// 3. Загружаем историю сообщений → messages
    /// 4. Загружаем проекты треда → activeProjects (IT-06)
    /// 5. Собираем MemoryContext с именами проектов → activeMemoryContext (IT-08 финал)
    /// 6. Синхронизируем ActiveMemoryContext в ToolExecutionService (IT-08)
    func selectThread(_ thread: ThreadMetadata) async {
        guard let store = threadStore else { return }

        self.activeThread = thread

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

        // Загружаем проекты треда (IT-06)
        // Делаем это ПОСЛЕ загрузки истории — не блокируем основной поток
        await loadProjectsForThread(thread)

        // IT-08 финал: собираем MemoryContext с именами проектов ПОСЛЕ загрузки проектов.
        // ПОЧЕМУ ПОСЛЕ loadProjectsForThread: нужен актуальный activeProjects с именами.
        // buildAndSyncMemoryContext() использует activeProjects для MemoryContext.projectInfos.
        buildAndSyncMemoryContext()

        // IT-08: синхронизируем ActiveMemoryContext в ToolExecutionService.
        // ПОЧЕМУ ПОСЛЕ loadProjectsForThread: нам нужен актуальный activeProjects с UUID.
        await syncActiveMemoryContext()
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
    /// Новый тред начинается с пустой историей и без проектов.
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
                    // Сбрасываем проекты — новый тред начинается без проектов
                    self.activeProjects = []
                    // IT-08 финал: синхронизируем пустой контекст — новый тред без проектов
                    buildAndSyncMemoryContext()
                    await syncActiveMemoryContext()
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

    // MARK: - Управление проектами в треде (IT-06)

    /// Загружает проекты для указанного треда из ProjectStore.
    ///
    /// ПОЧЕМУ ОТДЕЛЬНЫЙ МЕТОД:
    /// Вызывается из selectThread() и после добавления/удаления проекта.
    /// Изолирован для переиспользования без дублирования кода.
    private func loadProjectsForThread(_ thread: ThreadMetadata) async {
        guard let pStore = projectStore else {
            self.activeProjects = []
            return
        }

        guard !thread.projectIds.isEmpty else {
            // У треда нет проектов — сразу очищаем список без запроса к БД
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

    /// Добавляет папку как проект к активному треду.
    ///
    /// АЛГОРИТМ:
    /// 1. Создаём security-scoped bookmark для выбранной папки
    /// 2. Проверяем, не добавлен ли уже этот проект (по имени папки)
    /// 3. Если нет — создаём ProjectEntity в ProjectStore
    /// 4. Добавляем UUID проекта в ThreadEntity.projectBindingsJSON через ThreadStore
    /// 5. Обновляем activeProjects, activeMemoryContext (с именами!) и syncActiveMemoryContext
    ///
    /// ПОЧЕМУ BOOKMARK, А НЕ ПУТЬ:
    /// macOS sandbox требует security-scoped bookmark для постоянного доступа к папке.
    /// Путь ненадёжен — папку могут переименовать/переместить.
    ///
    /// - Parameter url: URL папки выбранной пользователем через NSOpenPanel
    func addProject(url: URL) {
        guard let pStore = projectStore,
              let tStore = threadStore,
              let thread = activeThread else { return }

        Task {
            do {
                // Создаём security-scoped bookmark
                let bookmarkData: Data
                do {
                    bookmarkData = try url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                } catch {
                    // Фолбэк без security scope (для тестирования или без sandbox)
                    bookmarkData = try url.bookmarkData(
                        options: [],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                }

                let displayName = url.lastPathComponent

                // Проверяем, нет ли уже проекта с таким именем в текущем треде
                // ПОЧЕМУ ПО ИМЕНИ, А НЕ BOOKMARK:
                // Сравнение bookmark-ов ненадёжно (байты могут отличаться при пересоздании).
                // Имя папки — достаточный идентификатор для UX (пользователь видит имя).
                let alreadyAdded = activeProjects.contains { $0.displayName == displayName }
                guard !alreadyAdded else {
                    print("[ChappieViewModel] ℹ️ Проект '\(displayName)' уже добавлен в тред")
                    return
                }

                // Создаём проект в ProjectStore
                let projectId = try await pStore.addProject(
                    displayName: displayName,
                    bookmarkData: bookmarkData
                )

                // Добавляем UUID в тред через ThreadStore
                var updatedIds = thread.projectIds
                updatedIds.append(projectId)
                try await tStore.updateProjectBindings(updatedIds, forThreadId: thread.id)

                // Обновляем список тредов (метаданные изменились)
                let refreshed = try await tStore.loadThreads()
                self.threads = refreshed

                // Обновляем activeThread и перезагружаем проекты
                if let updatedThread = refreshed.first(where: { $0.id == thread.id }) {
                    self.activeThread = updatedThread
                    // Перезагружаем проекты треда
                    await loadProjectsForThread(updatedThread)
                    // IT-08 финал: синхронизируем MemoryContext с именами после добавления
                    buildAndSyncMemoryContext()
                    // IT-08: синхронизируем ActiveMemoryContext с реальными UUID
                    await syncActiveMemoryContext()
                }

                print("[ChappieViewModel] ✅ Проект '\(displayName)' добавлен в тред '\(thread.title)'")
            } catch {
                print("[ChappieViewModel] ⚠️ Ошибка добавления проекта: \(error)")
            }
        }
    }

    /// Удаляет проект из активного треда (ProjectEntity НЕ удаляется из БД).
    ///
    /// ПОЧЕМУ НЕ УДАЛЯЕМ ProjectEntity:
    /// Проект может быть привязан к другим тредам.
    /// Удаление из треда = просто убрать UUID из projectBindingsJSON.
    /// Полное удаление проекта из системы — отдельная операция (не реализована в IT-06).
    ///
    /// - Parameter projectId: UUID проекта для удаления из треда
    func removeProject(id projectId: UUID) {
        guard let tStore = threadStore,
              let thread = activeThread else { return }

        Task {
            do {
                // Убираем UUID из списка привязок треда
                var updatedIds = thread.projectIds
                updatedIds.removeAll { $0 == projectId }
                try await tStore.updateProjectBindings(updatedIds, forThreadId: thread.id)

                // Обновляем список тредов
                let refreshed = try await tStore.loadThreads()
                self.threads = refreshed

                // Обновляем activeThread и перезагружаем проекты
                if let updatedThread = refreshed.first(where: { $0.id == thread.id }) {
                    self.activeThread = updatedThread
                    // Перезагружаем проекты треда
                    await loadProjectsForThread(updatedThread)
                    // IT-08 финал: синхронизируем MemoryContext с именами после удаления
                    buildAndSyncMemoryContext()
                    // IT-08: синхронизируем ActiveMemoryContext с реальными UUID
                    await syncActiveMemoryContext()
                }

                print("[ChappieViewModel] 🗑 Проект убран из треда '\(thread.title)'")
            } catch {
                print("[ChappieViewModel] ⚠️ Ошибка удаления проекта из треда: \(error)")
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
    /// ОБРАБОТКА ОТМЕНЫ (FIX-CANCELLED):
    /// Task может быть отменён если пользователь быстро нажимает отправить повторно
    /// или если View пересоздаётся. В этом случае URLSession бросает URLError(.cancelled),
    /// AITunnelClient оборачивает его в ChappieError.cancelled.
    /// Мы ловим CancellationError и ChappieError.cancelled ОТДЕЛЬНО — тихо завершаем
    /// без показа ошибки пользователю. Это нормальное поведение, не баг.
    ///
    /// СОХРАНЕНИЕ В ТРЕД (IT-05):
    /// После добавления ответа в messages — сохраняем историю в активный тред через ThreadStore.
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
        // Используем activeMemoryContext — он содержит projectInfos с именами (IT-08 финал)
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

            } catch is CancellationError {
                // Task был отменён — это нормальное поведение, не показываем ошибку.
                // Например: пользователь быстро нажал отправить повторно.
                // Просто тихо завершаем — сбрасываем состояние UI.
                print("[ChappieViewModel] ℹ️ Запрос отменён (CancellationError) — тихое завершение")
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    self.streamingText = ""
                    self.currentToolCall = nil
                }

            } catch ChappieError.cancelled {
                // URLSession.cancelled — аналогично CancellationError.
                // AITunnelClient оборачивает URLError(.cancelled) в ChappieError.cancelled.
                print("[ChappieViewModel] ℹ️ Запрос отменён (URLError.cancelled) — тихое завершение")
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    self.streamingText = ""
                    self.currentToolCall = nil
                }

            } catch {
                // Реальная ошибка — показываем пользователю.
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

        // IT-07: если ProjectStore уже создан (ModelContainer подключён раньше воркспейса),
        // регистрируем обработчики немедленно.
        // В обычном сценарии — регистрация происходит в setModelContainer().
        if let pStore = projectStore, let tStore = threadStore {
            registerProjectToolHandlers(toolService: ts, projectStore: pStore, threadStore: tStore)
        }

        // IT-08: синхронизируем ActiveMemoryContext с реальными UUID при пересоздании сервисов.
        // При setWorkspace() activeProjects и activeThread уже могут быть заполнены.
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
