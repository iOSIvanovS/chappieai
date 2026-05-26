// ToolExecutionService.swift
// ChappieCore
//
// ЗАЧЕМ ЭТОТ ФАЙЛ:
// Сервис выполнения инструментов ИИ-агента. Принимает вызов функции от модели,
// парсит аргументы и выполняет действие: файловая система, память или MCP-сервер.
//
// АРХИТЕКТУРА MCP-СОЕДИНЕНИЯ:
// MCPToolBridge создаётся с явным socketPath, который передаётся через init().
//
// ПОЧЕМУ socketPath ПРИХОДИТ СНАРУЖИ, А НЕ ХАРДКОДИТСЯ:
// Путь к Unix Domain Socket вычисляется MCPHelperLauncher в Chappie.app через
// FileManager.default.temporaryDirectory — это путь ВНУТРИ sandbox-контейнера.
// ChappieCore — отдельный Swift Package, он не имеет доступа к MCPHelperLauncher.
// Поэтому путь передаётся через DI: Chappie.app знает путь → передаёт в ToolExecutionService.
//
// ЦЕПОЧКА ПЕРЕДАЧИ ПУТИ:
// MCPHelperLauncher.socketPath
//   → ChappieViewModel.initializeServices(for:)
//     → ToolExecutionService(socketPath:)
//       → MCPToolBridge(socketPath:)
//         → POSIX connect() → ChappieMCP сервер
//
// АРХИТЕКТУРНОЕ РЕШЕНИЕ — МОНОФИЗИТНАЯ АРХИТЕКТУРА:
// После перехода к монофизитной архитектуре (один агент — Чаппи)
// инструмент `delegate_task` был полностью удалён. apiKey тоже не нужен —
// никаких саб-агентов нет.
//
// АРХИТЕКТУРНОЕ РЕШЕНИЕ — ИНСТРУМЕНТЫ УПРАВЛЕНИЯ ПРОЕКТАМИ (IT-07):
// Инструменты add_project_to_thread и remove_project_from_thread позволяют Чаппи
// самостоятельно управлять проектами в активном треде в процессе разговора.
//
// АРХИТЕКТУРНОЕ РЕШЕНИЕ — ТРЁХУРОВНЕВАЯ ПАМЯТЬ (IT-08):
// Инструменты memorize/recall/search_memory/delete_memory работают с UUID-based scope:
//   - scope="global"       → глобальная память (всегда доступна)
//   - scope="thread"       → память активного треда (UUID из ActiveMemoryContext.threadId)
//   - targetName="Chappie" → память проекта "Chappie" (UUID из ActiveMemoryContext.projects)
//
// МАППИНГ SCOPE (IT-08):
// resolveScope() преобразует (scope, targetName) → строку scope для MemoryManager:
//   - ("global", _)          → "global"
//   - ("thread", _)          → UUID активного треда
//   - (_, "Chappie")         → UUID проекта "Chappie" среди прикреплённых
//   - неизвестный scope      → "global" (безопасный дефолт)
//
// РАЗРЕШЕНИЕ КОНФЛИКТОВ (IT-08):
// Если targetName указан, но такого проекта нет в треде — возвращаем ошибку.
// Чаппи должен сначала добавить проект через add_project_to_thread.
//
// ПРОБЛЕМА ЗАВИСИМОСТЕЙ:
// ToolExecutionService живёт в ChappieCore, а ProjectStore/ThreadStore тоже в ChappieCore,
// но создаются и управляются из Chappie.app (ChappieViewModel).
// Прямая ссылка ToolExecutionService → ThreadStore/ProjectStore создала бы циклическую
// зависимость через ViewModel и нарушила бы принцип инверсии зависимостей.
//
// РЕШЕНИЕ — ПАТТЕРН CALLBACK/CLOSURE:
// ViewModel регистрирует async-замыкания в ToolExecutionService через registerProjectHandlers().
// Когда Чаппи вызывает инструмент → ToolExecutionService вызывает замыкание →
// ViewModel выполняет операцию с ProjectStore/ThreadStore → возвращает строковый результат.
// Это сохраняет чистоту зависимостей: ChappieCore не знает о Chappie.app типах.
//
// SENDABLE-ЗАМЫКАНИЯ:
// Замыкания помечены @Sendable — обязательно для Swift 6 при передаче через actor-границы.
// ViewModel захватывает только Sendable-типы (UUID, String) в этих замыканиях.
//
// АРХИТЕКТУРНОЕ РЕШЕНИЕ — ЗАЩИТА ФАЙЛОВЫХ ИНСТРУМЕНТОВ (PROJECT GUARD):
// Файловые инструменты (list_files, read_file, write_file, delete_file, git_*, build_*)
// должны быть доступны ТОЛЬКО когда к треду привязан хотя бы один проект.
// Это защищает от случайного использования инструментов в "свободном чате" без контекста.
//
// КАК РАБОТАЕТ PROJECT GUARD:
// ViewModel вызывает setActiveMemoryContext() при каждой смене треда или изменении проектов.
// execute() проверяет activeMemoryContext.hasProjects перед выполнением файловых инструментов.
// Инструменты памяти и управления проектами — работают всегда.

import Foundation

// MARK: - ScopeResolution (IT-08)

/// Результат маппинга scope из параметров инструмента в строку для MemoryStore.
///
/// ПОЧЕМУ НЕ Result<String, Error>:
/// Swift требует чтобы тип ошибки в Result реализовывал протокол Error.
/// Для нашего случая (строковые сообщения об ошибках) удобнее использовать
/// простой enum с двумя случаями — без лишних зависимостей.
private enum ScopeResolution {
    /// Успешно определён scope для MemoryStore
    case resolved(String)
    /// Ошибка маппинга — строка с описанием для ответа Чаппи
    case failed(String)
}

/// Сервис выполнения инструментов ИИ-агента.
///
/// Зачем actor: async операции с файловой системой и сетью требуют
/// правильной изоляции в Swift 6. Actor гарантирует отсутствие гонок данных.
public actor ToolExecutionService {
    private let fileSystem: FileSystemManager
    private let memoryManager: MemoryManager

    /// Мост к ChappieMCP серверу для git и xcodebuild инструментов.
    /// Создаётся один раз с путём к сокету от MCPHelperLauncher.
    private let mcpBridge: MCPToolBridge

    // MARK: - Активный контекст памяти (IT-08)

    /// Контекст активного треда — содержит threadId и список проектов (UUID + имя).
    ///
    /// ЗАЧЕМ ХРАНИТЬ ЗДЕСЬ (IT-08):
    /// При вызове инструментов памяти (memorize, recall и т.д.) нам нужно знать:
    ///   - UUID активного треда (для scope="thread")
    ///   - UUID каждого проекта по имени (для targetName="Chappie")
    /// Раньше хранились только имена проектов (для PROJECT GUARD).
    /// Теперь хранится полный ActiveMemoryContext — он покрывает обе нужды.
    ///
    /// КОГДА ОБНОВЛЯЕТСЯ:
    /// ViewModel вызывает setActiveMemoryContext() при:
    ///   - выборе треда (selectThread)
    ///   - добавлении/удалении проекта (addProject / removeProject / через инструменты)
    private var activeMemoryContext: ActiveMemoryContext = .empty

    /// Есть ли хотя бы один проект в активном треде.
    ///
    /// ИСПОЛЬЗУЕТСЯ В:
    /// execute() — как guard перед выполнением файловых/git/build инструментов.
    private var hasActiveProjects: Bool {
        activeMemoryContext.hasProjects
    }

    // MARK: - Обработчики проектов (IT-07)

    /// Замыкание для добавления проекта к активному треду.
    private var addProjectHandler: (@Sendable (String) async -> String)?

    /// Замыкание для удаления проекта из активного треда.
    private var removeProjectHandler: (@Sendable (String) async -> String)?

    /// Замыкание для получения списка проектов активного треда.
    private var listProjectsHandler: (@Sendable () async -> String)?

    /// Инициализатор сервиса.
    ///
    /// - Parameters:
    ///   - fileSystem: Менеджер файловой системы проекта.
    ///   - memoryManager: Менеджер долгосрочной памяти.
    ///   - socketPath: Путь к Unix Domain Socket файлу ChappieMCP.
    public init(
        fileSystem: FileSystemManager,
        memoryManager: MemoryManager,
        socketPath: String = "/tmp/com.chappie.mcp.sock"
    ) {
        self.fileSystem = fileSystem
        self.memoryManager = memoryManager
        self.mcpBridge = MCPToolBridge(socketPath: socketPath)
    }

    // MARK: - Обновление активного контекста памяти (IT-08)

    /// Обновляет активный контекст памяти треда.
    ///
    /// КОГДА ВЫЗЫВАТЬ:
    /// Из ChappieViewModel при каждом изменении активного треда или проектов:
    ///   - selectThread() — после загрузки проектов треда
    ///   - reloadAfterProjectChange() — после add/remove через инструменты Чаппи
    ///   - addProject(url:) / removeProject(id:) — после ручного изменения через UI
    ///
    /// - Parameter context: Новый контекст с threadId и списком проектов (UUID + имя)
    public func setActiveMemoryContext(_ context: ActiveMemoryContext) {
        self.activeMemoryContext = context
        if context.projects.isEmpty {
            print("[ToolExecutionService] 🔒 Файловые инструменты заблокированы (нет проектов в треде)")
        } else {
            let names = context.projectNames.joined(separator: ", ")
            print("[ToolExecutionService] 🔓 Файловые инструменты разблокированы: \(names)")
        }
    }

    /// Обратная совместимость — старый метод setActiveProjectNames (IT-07).
    ///
    /// ОГРАНИЧЕНИЕ (IT-08): не знает UUID проектов — создаёт контекст только с именами.
    /// Поэтому targetName в инструментах памяти не сможет найти UUID проекта.
    /// Полноценная работа памяти требует setActiveMemoryContext() с реальными UUID.
    ///
    /// ПОЧЕМУ ОСТАВЛЕН:
    /// ChappieViewModel ещё вызывает syncProjectGuard() → setActiveProjectNames() в нескольких местах.
    /// Этот метод — временный мост до полного перехода ViewModel на setActiveMemoryContext().
    public func setActiveProjectNames(_ names: [String]) {
        let projects = names.map { name in
            // UUID-заглушка — достаточно для PROJECT GUARD, но не для маппинга памяти.
            // Полноценный UUID будет только после перехода на setActiveMemoryContext().
            ActiveMemoryContext.ProjectInfo(id: UUID(), name: name)
        }
        self.activeMemoryContext = ActiveMemoryContext(
            threadId: activeMemoryContext.threadId,
            projects: projects
        )
        if names.isEmpty {
            print("[ToolExecutionService] 🔒 Файловые инструменты заблокированы (нет проектов в треде)")
        } else {
            print("[ToolExecutionService] 🔓 Файловые инструменты разблокированы: \(names.joined(separator: ", "))")
        }
    }

    // MARK: - Регистрация обработчиков проектов (IT-07)

    /// Регистрирует обработчики для инструментов управления проектами.
    ///
    /// КОГДА ВЫЗЫВАТЬ:
    /// Из ChappieViewModel.setModelContainer() — после создания ProjectStore и ThreadStore.
    ///
    /// - Parameters:
    ///   - addProject: Замыкание добавления проекта (принимает displayName, возвращает результат)
    ///   - removeProject: Замыкание удаления проекта (принимает displayName, возвращает результат)
    ///   - listProjects: Замыкание списка проектов (возвращает строку)
    public func registerProjectHandlers(
        addProject: @escaping @Sendable (String) async -> String,
        removeProject: @escaping @Sendable (String) async -> String,
        listProjects: @escaping @Sendable () async -> String
    ) {
        self.addProjectHandler = addProject
        self.removeProjectHandler = removeProject
        self.listProjectsHandler = listProjects
        print("[ToolExecutionService] ✅ Обработчики проектов зарегистрированы")
    }

    // MARK: - Маппинг scope для памяти (IT-08)

    /// Преобразует параметры инструмента (scope, targetName) в строку scope для MemoryManager.
    ///
    /// ЛОГИКА МАППИНГА (IT-08):
    /// 1. targetName задан → ищем проект с таким именем в активном треде
    ///    - Найден → возвращаем UUID проекта в строке
    ///    - Не найден → возвращаем ошибку (проект не прикреплён к треду)
    /// 2. scope="global" (или не задан) → "global"
    /// 3. scope="thread" → UUID активного треда (ошибка если нет треда)
    /// 4. Неизвестный scope → "global" (безопасный дефолт)
    ///
    /// ПОЧЕМУ ScopeResolution, А НЕ Result<String, Error>:
    /// Swift требует чтобы тип ошибки реализовывал Error. Для строковых сообщений
    /// удобнее собственный enum без лишних зависимостей.
    ///
    /// - Parameters:
    ///   - scopeParam: Значение параметра "scope" из инструмента (nil = не задан)
    ///   - targetName: Значение параметра "targetName" из инструмента (nil = не задан)
    /// - Returns: .resolved(scopeString) или .failed(errorMessage)
    private func resolveScope(scopeParam: String?, targetName: String?) -> ScopeResolution {
        // Приоритет 1: targetName — явное указание проекта по имени
        if let name = targetName, !name.isEmpty {
            if let project = activeMemoryContext.projects.first(where: { $0.name == name }) {
                return .resolved(project.id.uuidString)
            } else {
                // Проект не найден — информативная ошибка с подсказкой
                let attached = activeMemoryContext.projectNames.isEmpty
                    ? "нет прикреплённых проектов"
                    : activeMemoryContext.projectNames.joined(separator: ", ")
                return .failed(
                    "Проект '\(name)' не найден в текущем треде. " +
                    "Прикреплённые проекты: \(attached). " +
                    "Используй add_project_to_thread чтобы добавить проект."
                )
            }
        }

        // Приоритет 2: scope="global" (дефолт если не задан)
        let scope = scopeParam ?? "global"
        if scope == "global" {
            return .resolved("global")
        }

        // Приоритет 3: scope="thread"
        if scope == "thread" {
            if let threadId = activeMemoryContext.threadId {
                return .resolved(threadId.uuidString)
            } else {
                return .failed(
                    "Нет активного треда. Тредовая память недоступна. " +
                    "Используй scope=\"global\" для глобальной памяти."
                )
            }
        }

        // Дефолт: неизвестный scope → глобальная память (безопасный фолбэк)
        print("[ToolExecutionService] ⚠️ Неизвестный scope='\(scope)', используем 'global'")
        return .resolved("global")
    }

    // MARK: - Доступные инструменты

    /// Массив доступных ИИ-агенту инструментов.
    ///
    /// Этот массив передаётся в каждый API-запрос, чтобы модель знала,
    /// какие функции она может вызывать. Список строго соответствует
    /// монофизитной архитектуре: файловая система, память и MCP-инструменты.
    ///
    /// ИНСТРУМЕНТЫ ПАМЯТИ (IT-08):
    /// memorize/recall/search_memory/delete_memory работают с трёхуровневой памятью.
    /// scope="global" | scope="thread" | targetName="ProjectName"
    ///
    /// ИНСТРУМЕНТЫ ПРОЕКТОВ (IT-07):
    /// add_project_to_thread, remove_project_from_thread, list_thread_projects —
    /// позволяют Чаппи управлять проектами в активном треде прямо в процессе разговора.
    public var availableTools: [AITool] {
        return [
            // --- Инструменты файловой системы ---

            AITool(function: AIFunctionDefinition(
                name: "list_files",
                description: "Получить список всех файлов в проекте (относительные пути).",
                parameters: AIToolParameters(properties: [:], required: [])
            )),

            AITool(function: AIFunctionDefinition(
                name: "read_file",
                description: "Прочитать содержимое файла в проекте.",
                parameters: AIToolParameters(
                    properties: [
                        "path": AIToolProperty(type: "string", description: "Относительный путь к файлу")
                    ],
                    required: ["path"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "write_file",
                description: "Создать новый или полностью перезаписать существующий файл (подпапки создадутся автоматически).",
                parameters: AIToolParameters(
                    properties: [
                        "path": AIToolProperty(type: "string", description: "Относительный путь к файлу"),
                        "content": AIToolProperty(type: "string", description: "Полный код или текст для записи в файл")
                    ],
                    required: ["path", "content"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "delete_file",
                description: "Удалить файл из проекта.",
                parameters: AIToolParameters(
                    properties: [
                        "path": AIToolProperty(type: "string", description: "Относительный путь к удаляемому файлу")
                    ],
                    required: ["path"]
                )
            )),

            // --- Инструменты долгосрочной памяти (IT-08) ---
            //
            // ТРЁХУРОВНЕВАЯ ПАМЯТЬ:
            // scope="global"       → глобальная память (кросс-проектные факты, правила)
            // scope="thread"       → память активного треда (контекст текущей задачи)
            // targetName="Name"    → память конкретного проекта (UUID ищется по имени)
            //
            // ЕСЛИ НЕ ЗАДАН НИ scope НИ targetName → глобальная память (дефолт)
            //
            // РАЗРЕШЕНИЕ КОНФЛИКТОВ:
            // Если инструкции в разных уровнях памяти противоречат друг другу —
            // остановись, объясни конфликт пользователю и жди решения.
            // Обнови память так, чтобы конфликт был устранён.

            AITool(function: AIFunctionDefinition(
                name: "memorize",
                description: """
                Запомнить важную информацию, договоренность, факт или правило в долгосрочную память.
                Используй scope для выбора уровня:
                  scope="global" — глобальная память (кросс-проектные правила, факты о пользователе).
                  scope="thread" — память активного треда (контекст текущей задачи).
                  targetName="ProjectName" — память конкретного проекта (архитектура, пайплайны).
                Если scope и targetName не заданы — сохраняется в глобальную память.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "key": AIToolProperty(type: "string", description: "Уникальный ключ/тема для запоминания"),
                        "type": AIToolProperty(type: "string", description: "Тип данных (например: rule, fact, persona, project_map)"),
                        "jsonString": AIToolProperty(type: "string", description: "Данные в формате JSON строки"),
                        "scope": AIToolProperty(type: "string", description: "Область видимости: global (по умолчанию) или thread"),
                        "targetName": AIToolProperty(type: "string", description: "Имя конкретного проекта среди прикреплённых к треду (например, Chappie или ChappieCore) для сохранения памяти строго в этом проекте")
                    ],
                    required: ["key", "type", "jsonString"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "recall",
                description: """
                Вспомнить информацию из долгосрочной памяти по ключу.
                Используй scope или targetName чтобы указать уровень памяти:
                  scope="global" — глобальная память.
                  scope="thread" — память активного треда.
                  targetName="ProjectName" — память конкретного проекта.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "key": AIToolProperty(type: "string", description: "Уникальный ключ/тема, который нужно вспомнить"),
                        "scope": AIToolProperty(type: "string", description: "Область видимости: global (по умолчанию) или thread"),
                        "targetName": AIToolProperty(type: "string", description: "Имя конкретного проекта среди прикреплённых к треду для поиска памяти строго в этом проекте")
                    ],
                    required: ["key"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "search_memory",
                description: """
                Найти все записи в памяти по определенному типу.
                Используй scope или targetName чтобы указать уровень памяти:
                  scope="global" — глобальная память.
                  scope="thread" — память активного треда.
                  targetName="ProjectName" — память конкретного проекта.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "type": AIToolProperty(type: "string", description: "Тип данных для поиска (например: rule, fact)"),
                        "scope": AIToolProperty(type: "string", description: "Область видимости: global (по умолчанию) или thread"),
                        "targetName": AIToolProperty(type: "string", description: "Имя конкретного проекта среди прикреплённых к треду для поиска памяти строго в этом проекте")
                    ],
                    required: ["type"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "delete_memory",
                description: """
                Удалить запись из долгосрочной памяти по ключу.
                Используй scope или targetName чтобы указать уровень памяти:
                  scope="global" — глобальная память.
                  scope="thread" — память активного треда.
                  targetName="ProjectName" — память конкретного проекта.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "key": AIToolProperty(type: "string", description: "Уникальный ключ/тема для удаления"),
                        "scope": AIToolProperty(type: "string", description: "Область видимости: global (по умолчанию) или thread"),
                        "targetName": AIToolProperty(type: "string", description: "Имя конкретного проекта среди прикреплённых к треду для удаления памяти строго из этого проекта")
                    ],
                    required: ["key"]
                )
            )),

            // --- MCP: Инструменты Git ---

            AITool(function: AIFunctionDefinition(
                name: "git_status",
                description: "Показать текущий статус git-репозитория: изменённые, новые и удалённые файлы.",
                parameters: AIToolParameters(properties: [:], required: [])
            )),

            AITool(function: AIFunctionDefinition(
                name: "git_diff",
                description: "Показать содержимое изменений в коде.",
                parameters: AIToolParameters(
                    properties: [
                        "staged": AIToolProperty(type: "string", description: "true — показать staged изменения (после git add), false — unstaged (по умолчанию)")
                    ],
                    required: []
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "git_add",
                description: "Добавить файлы в staging area (подготовить к коммиту).",
                parameters: AIToolParameters(
                    properties: [
                        "paths": AIToolProperty(type: "string", description: "Пути через пробел, или '.' для всех файлов (по умолчанию '.')")
                    ],
                    required: []
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "git_commit",
                description: "Создать git-коммит с заданным сообщением.",
                parameters: AIToolParameters(
                    properties: [
                        "message": AIToolProperty(type: "string", description: "Текст коммита")
                    ],
                    required: ["message"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "git_log",
                description: "Показать историю последних коммитов.",
                parameters: AIToolParameters(
                    properties: [
                        "count": AIToolProperty(type: "string", description: "Количество коммитов (по умолчанию 10)")
                    ],
                    required: []
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "git_reset",
                description: "Убрать все файлы из staging area (git reset HEAD).",
                parameters: AIToolParameters(properties: [:], required: [])
            )),

            // --- MCP: Инструменты сборки ---

            AITool(function: AIFunctionDefinition(
                name: "build_project",
                description: "Собрать проект Chappie.xcodeproj через xcodebuild. Возвращает успех или список ошибок компиляции.",
                parameters: AIToolParameters(properties: [:], required: [])
            )),

            AITool(function: AIFunctionDefinition(
                name: "run_tests",
                description: "Запустить автотесты. Для ChappieCore используется swift test, для Chappie.app — xcodebuild test.",
                parameters: AIToolParameters(
                    properties: [
                        "target": AIToolProperty(type: "string", description: "Имя тест-таргета (например 'ChappieCoreTests'). Пусто = все тесты.")
                    ],
                    required: []
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "read_build_log",
                description: "Прочитать полный лог последней сборки или запуска тестов.",
                parameters: AIToolParameters(properties: [:], required: [])
            )),

            // --- Управление проектами в треде (IT-07) ---

            AITool(function: AIFunctionDefinition(
                name: "add_project_to_thread",
                description: "Добавить проект к текущему треду по имени папки. Используй когда пользователь просит привязать проект к беседе или когда задача явно относится к конкретному проекту.",
                parameters: AIToolParameters(
                    properties: [
                        "display_name": AIToolProperty(
                            type: "string",
                            description: "Отображаемое имя проекта (имя папки). Например: 'Chappie', 'MyApp', 'Backend'. Должно совпадать с реальным именем папки проекта."
                        )
                    ],
                    required: ["display_name"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "remove_project_from_thread",
                description: "Убрать проект из текущего треда по имени. Используй когда пользователь просит убрать проект из беседы или задача больше не касается этого проекта.",
                parameters: AIToolParameters(
                    properties: [
                        "display_name": AIToolProperty(
                            type: "string",
                            description: "Отображаемое имя проекта для удаления из треда. Должно точно совпадать с именем добавленного проекта."
                        )
                    ],
                    required: ["display_name"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "list_thread_projects",
                description: "Показать список проектов, привязанных к текущему треду. Используй чтобы узнать какие проекты уже добавлены перед add/remove операциями.",
                parameters: AIToolParameters(properties: [:], required: [])
            ))
        ]
    }

    // MARK: - Выполнение инструментов

    /// Выполняет указанный инструмент и возвращает строковый результат.
    ///
    /// Зачем возвращать строку: API Claude ожидает результат вызова инструмента
    /// в виде строки — она добавляется в историю чата как сообщение с ролью "tool".
    ///
    /// PROJECT GUARD:
    /// Перед выполнением файловых/git/build инструментов проверяем наличие проектов.
    /// Если проектов нет — возвращаем информативную ошибку, а не выполняем операцию.
    /// Инструменты памяти и управления проектами не требуют привязанного проекта.
    ///
    /// - Parameter call: Объект вызова инструмента с именем и JSON-аргументами.
    /// - Returns: Результат выполнения в виде строки (успех или описание ошибки).
    public func execute(call: AIToolCall) async -> String {
        let name = call.function.name
        let argsData = call.function.arguments.data(using: .utf8) ?? Data()

        // Набор инструментов, требующих привязанного проекта.
        // ПОЧЕМУ SET: O(1) поиск по имени — эффективнее массива при частых вызовах.
        let projectRequiredTools: Set<String> = [
            "list_files", "read_file", "write_file", "delete_file",
            "git_status", "git_diff", "git_add", "git_commit",
            "git_log", "git_reset",
            "build_project", "run_tests", "read_build_log"
        ]

        // PROJECT GUARD: блокируем файловые/git/build инструменты без проекта в треде.
        if projectRequiredTools.contains(name) && !hasActiveProjects {
            return """
            ❌ Инструмент '\(name)' недоступен: к текущему треду не привязан ни один проект.

            Чтобы использовать файловые инструменты и git-команды, нужно сначала добавить проект к треду:
            • Нажми кнопку '+' в строке проектов над чатом, или
            • Скажи мне: "Добавь проект [имя папки]" — я вызову add_project_to_thread.
            """
        }

        do {
            switch name {

            // MARK: - Файловая система

            case "list_files":
                let files = try await fileSystem.listFiles()
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                let data = try encoder.encode(files)
                return String(data: data, encoding: .utf8) ?? "[]"

            case "read_file":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let path = args["path"] else {
                    return "Ошибка: Неверные аргументы для read_file"
                }
                return try await fileSystem.readFile(at: path)

            case "write_file":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let path = args["path"],
                      let content = args["content"] else {
                    return "Ошибка: Неверные аргументы для write_file"
                }
                try await fileSystem.writeFile(at: path, content: content)
                return "Успешно: Файл \(path) записан."

            case "delete_file":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let path = args["path"] else {
                    return "Ошибка: Неверные аргументы для delete_file"
                }
                try await fileSystem.deleteFile(at: path)
                return "Успешно: Файл \(path) удален."

            // MARK: - Долгосрочная память (IT-08)
            //
            // НОВЫЙ API: scope="global"|"thread" или targetName="ProjectName"
            // resolveScope() преобразует параметры в строку scope для MemoryManager.
            // MemoryManager пишет/читает из MemoryStore (SwiftData) по UUID-scope.

            case "memorize":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let key = args["key"],
                      let type = args["type"],
                      let jsonString = args["jsonString"] else {
                    return "Ошибка: Неверные аргументы для memorize (обязательны: key, type, jsonString)"
                }

                switch resolveScope(scopeParam: args["scope"], targetName: args["targetName"]) {
                case .failed(let msg):
                    return "❌ memorize: \(msg)"
                case .resolved(let scopeString):
                    if let error = await memoryManager.saveMemoryEntry(
                        key: key, type: type, jsonString: jsonString, scope: scopeString
                    ) {
                        return "❌ memorize: \(error)"
                    }
                    // Формируем читаемую метку scope для ответа
                    let scopeLabel: String
                    if scopeString == "global" {
                        scopeLabel = "глобальной памяти"
                    } else if scopeString == activeMemoryContext.threadId?.uuidString {
                        scopeLabel = "памяти треда"
                    } else {
                        let projectName = args["targetName"] ?? scopeString
                        scopeLabel = "памяти проекта '\(projectName)'"
                    }
                    return "✅ Запись '\(key)' сохранена в \(scopeLabel)."
                }

            case "recall":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let key = args["key"] else {
                    return "Ошибка: Неверные аргументы для recall (обязателен: key)"
                }

                switch resolveScope(scopeParam: args["scope"], targetName: args["targetName"]) {
                case .failed(let msg):
                    return "❌ recall: \(msg)"
                case .resolved(let scopeString):
                    if let value = await memoryManager.readMemoryEntry(key: key, scope: scopeString) {
                        return value
                    } else {
                        return "Запись по ключу '\(key)' не найдена в scope '\(scopeString)'."
                    }
                }

            case "search_memory":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let type = args["type"] else {
                    return "Ошибка: Неверные аргументы для search_memory (обязателен: type)"
                }

                switch resolveScope(scopeParam: args["scope"], targetName: args["targetName"]) {
                case .failed(let msg):
                    return "❌ search_memory: \(msg)"
                case .resolved(let scopeString):
                    let results = await memoryManager.searchMemoryEntries(type: type, scope: scopeString)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .prettyPrinted
                    let data = try encoder.encode(results)
                    return String(data: data, encoding: .utf8) ?? "{}"
                }

            case "delete_memory":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let key = args["key"] else {
                    return "Ошибка: Неверные аргументы для delete_memory (обязателен: key)"
                }

                switch resolveScope(scopeParam: args["scope"], targetName: args["targetName"]) {
                case .failed(let msg):
                    return "❌ delete_memory: \(msg)"
                case .resolved(let scopeString):
                    if let error = await memoryManager.deleteMemoryEntry(key: key, scope: scopeString) {
                        return "❌ delete_memory: \(error)"
                    }
                    return "✅ Запись '\(key)' удалена из scope '\(scopeString)'."
                }

            // MARK: - MCP: Git инструменты

            case "git_status":
                return await mcpBridge.execute(tool: "git_status")

            case "git_diff":
                let args = (try? JSONDecoder().decode([String: String].self, from: argsData)) ?? [:]
                return await mcpBridge.execute(tool: "git_diff", args: args)

            case "git_add":
                var args = (try? JSONDecoder().decode([String: String].self, from: argsData)) ?? [:]
                if args["paths"] == nil { args["paths"] = "." }
                return await mcpBridge.execute(tool: "git_add", args: args)

            case "git_commit":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let message = args["message"] else {
                    return "Ошибка: Аргумент 'message' обязателен для git_commit"
                }
                return await mcpBridge.execute(tool: "git_commit", args: ["message": message])

            case "git_log":
                let args = (try? JSONDecoder().decode([String: String].self, from: argsData)) ?? [:]
                return await mcpBridge.execute(tool: "git_log", args: args)

            case "git_reset":
                return await mcpBridge.execute(tool: "git_reset")

            // MARK: - MCP: Build инструменты

            case "build_project":
                return await mcpBridge.execute(tool: "build_project")

            case "run_tests":
                let args = (try? JSONDecoder().decode([String: String].self, from: argsData)) ?? [:]
                return await mcpBridge.execute(tool: "run_tests", args: args)

            case "read_build_log":
                return await mcpBridge.execute(tool: "read_build_log")

            // MARK: - Управление проектами в треде (IT-07)

            case "add_project_to_thread":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let displayName = args["display_name"], !displayName.isEmpty else {
                    return "Ошибка: Аргумент 'display_name' обязателен для add_project_to_thread"
                }
                guard let handler = addProjectHandler else {
                    return "Ошибка: Инструменты управления проектами недоступны. Проверьте что ModelContainer подключён."
                }
                return await handler(displayName)

            case "remove_project_from_thread":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let displayName = args["display_name"], !displayName.isEmpty else {
                    return "Ошибка: Аргумент 'display_name' обязателен для remove_project_from_thread"
                }
                guard let handler = removeProjectHandler else {
                    return "Ошибка: Инструменты управления проектами недоступны. Проверьте что ModelContainer подключён."
                }
                return await handler(displayName)

            case "list_thread_projects":
                guard let handler = listProjectsHandler else {
                    return "Ошибка: Инструменты управления проектами недоступны. Проверьте что ModelContainer подключён."
                }
                return await handler()

            default:
                return "Ошибка: Неизвестный инструмент \(name)"
            }
        } catch {
            return "Ошибка при выполнении \(name): \(error.localizedDescription)"
        }
    }
}
