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
// ViewModel вызывает setActiveProjectNames() при каждой смене треда или изменении проектов.
// execute() проверяет hasActiveProjects перед выполнением файловых инструментов.
// Инструменты памяти (memorize, recall и т.д.) и управления проектами — работают всегда.
//
// ПОЧЕМУ NAMES, А НЕ IDs:
// ToolExecutionService не знает о UUID проектов (они в ChappieCore/ProjectStore, но
// доступны только через ViewModel). Нам достаточно знать ЕСТЬ ли проекты — для guard.
// Имена также используются в сообщении об ошибке, чтобы Чаппи понял контекст.

import Foundation

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

    // MARK: - Защита файловых инструментов (PROJECT GUARD)

    /// Имена проектов, привязанных к активному треду.
    ///
    /// ЗАЧЕМ ХРАНИТЬ ИМЕНА:
    /// Для проверки hasActiveProjects достаточно знать количество.
    /// Имена нужны для информативного сообщения об ошибке — Чаппи понимает
    /// что нужно сначала добавить проект, прежде чем работать с файлами.
    ///
    /// КОГДА ОБНОВЛЯЕТСЯ:
    /// ViewModel вызывает setActiveProjectNames() при:
    ///   - выборе треда (selectThread)
    ///   - добавлении проекта (addProject / add_project_to_thread)
    ///   - удалении проекта (removeProject / remove_project_from_thread)
    private var activeProjectNames: [String] = []

    /// Есть ли хотя бы один проект в активном треде.
    ///
    /// ИСПОЛЬЗУЕТСЯ В:
    /// execute() — как guard перед выполнением файловых/git/build инструментов.
    private var hasActiveProjects: Bool {
        !activeProjectNames.isEmpty
    }

    // MARK: - Обработчики проектов (IT-07)

    /// Замыкание для добавления проекта к активному треду.
    ///
    /// ЗАЧЕМ CLOSURE, А НЕ ПРЯМАЯ ССЫЛКА:
    /// ToolExecutionService создаётся при выборе воркспейса (до подключения ModelContainer).
    /// ProjectStore/ThreadStore создаются позже — когда ModelContainer готов.
    /// Closure регистрируется ViewModel когда оба условия выполнены.
    ///
    /// Принимает: displayName (имя папки)
    /// Возвращает: строку результата для ответа Чаппи
    private var addProjectHandler: (@Sendable (String) async -> String)?

    /// Замыкание для удаления проекта из активного треда.
    ///
    /// Принимает: displayName (имя проекта для удаления)
    /// Возвращает: строку результата для ответа Чаппи
    private var removeProjectHandler: (@Sendable (String) async -> String)?

    /// Замыкание для получения списка проектов активного треда.
    ///
    /// Возвращает: строку со списком проектов (JSON-массив имён) для ответа Чаппи
    private var listProjectsHandler: (@Sendable () async -> String)?

    /// Инициализатор сервиса.
    ///
    /// - Parameters:
    ///   - fileSystem: Менеджер файловой системы проекта.
    ///   - memoryManager: Менеджер долгосрочной памяти.
    ///   - socketPath: Путь к Unix Domain Socket файлу ChappieMCP.
    ///     Должен совпадать с путём, по которому ChappieMCP создал свой сокет.
    ///     Передаётся из MCPHelperLauncher.shared.socketPath через ChappieViewModel.
    ///     Дефолтное значение — строковый литерал (не константа!) из-за ограничений
    ///     Swift: default argument в public init не может ссылаться на internal/private символы.
    public init(
        fileSystem: FileSystemManager,
        memoryManager: MemoryManager,
        socketPath: String = "/tmp/com.chappie.mcp.sock"
    ) {
        self.fileSystem = fileSystem
        self.memoryManager = memoryManager
        // Создаём bridge с явным путём — он будет использовать именно этот сокет
        self.mcpBridge = MCPToolBridge(socketPath: socketPath)
    }

    // MARK: - Обновление активных проектов (PROJECT GUARD)

    /// Обновляет список имён проектов активного треда.
    ///
    /// КОГДА ВЫЗЫВАТЬ:
    /// Из ChappieViewModel при каждом изменении проектов активного треда:
    ///   - selectThread() — после загрузки проектов треда
    ///   - reloadAfterProjectChange() — после add/remove через инструменты Чаппи
    ///   - addProject(url:) / removeProject(id:) — после ручного изменения через UI
    ///
    /// ПОЧЕМУ НЕ АВТОМАТИЧЕСКИ:
    /// ToolExecutionService — actor, изолирован от MainActor ViewModel.
    /// Прямая подписка на @Observable-свойства невозможна через actor-границу.
    /// Явный вызов setActiveProjectNames() — простое и предсказуемое решение.
    ///
    /// - Parameter names: Имена проектов привязанных к активному треду (пустой = нет проектов)
    public func setActiveProjectNames(_ names: [String]) {
        self.activeProjectNames = names
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
    /// До этого момента инструменты add/remove project будут возвращать ошибку.
    ///
    /// ПОЧЕМУ @Sendable:
    /// Замыкания передаются через actor-границу (из @MainActor ViewModel в actor ToolExecutionService).
    /// Swift 6 требует @Sendable для таких замыканий.
    ///
    /// - Parameters:
    ///   - addProject: Замыкание добавления проекта (принимает displayName, возвращает результат)
    ///   - removeProject: Замыкание удаления проекта (принимает displayName, возвращает результат)
    ///   - listProjects: Замыкание списка проектов (возвращает JSON-строку)
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

    // MARK: - Доступные инструменты

    /// Массив доступных ИИ-агенту инструментов.
    ///
    /// Этот массив передаётся в каждый API-запрос, чтобы модель знала,
    /// какие функции она может вызывать. Список строго соответствует
    /// монофизитной архитектуре: файловая система, память и MCP-инструменты.
    ///
    /// ИНСТРУМЕНТЫ ПРОЕКТОВ (IT-07):
    /// add_project_to_thread, remove_project_from_thread, list_thread_projects —
    /// позволяют Чаппи управлять проектами в активном треде прямо в процессе разговора.
    /// Например: "Добавь проект MyApp в текущий тред" → Чаппи вызывает add_project_to_thread.
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

            // --- Инструменты долгосрочной памяти ---

            AITool(function: AIFunctionDefinition(
                name: "memorize",
                description: "Запомнить важную информацию, договоренность, факт или правило в долгосрочную память.",
                parameters: AIToolParameters(
                    properties: [
                        "key": AIToolProperty(type: "string", description: "Уникальный ключ/тема для запоминания"),
                        "type": AIToolProperty(type: "string", description: "Тип данных (например: rule, fact, persona, project_map)"),
                        "jsonString": AIToolProperty(type: "string", description: "Данные в формате JSON строки"),
                        "scope": AIToolProperty(type: "string", description: "Область видимости: project (по умолчанию) или global"),
                        "targetName": AIToolProperty(type: "string", description: "Имя конкретного таргета (например, Chappie или ChappieCore) для сохранения памяти строго в этом таргете")
                    ],
                    required: ["key", "type", "jsonString"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "recall",
                description: "Вспомнить информацию из долгосрочной памяти по ключу.",
                parameters: AIToolParameters(
                    properties: [
                        "key": AIToolProperty(type: "string", description: "Уникальный ключ/тема, который нужно вспомнить"),
                        "targetName": AIToolProperty(type: "string", description: "Имя конкретного таргета (например, Chappie или ChappieCore) для поиска памяти строго в этом таргете")
                    ],
                    required: ["key"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "search_memory",
                description: "Найти все записи в памяти по определенному типу.",
                parameters: AIToolParameters(
                    properties: [
                        "type": AIToolProperty(type: "string", description: "Тип данных для поиска (например: rule, fact)"),
                        "targetName": AIToolProperty(type: "string", description: "Имя конкретного таргета (например, Chappie или ChappieCore) для поиска памяти строго в этом таргете")
                    ],
                    required: ["type"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "delete_memory",
                description: "Удалить запись из долгосрочной памяти по ключу.",
                parameters: AIToolParameters(
                    properties: [
                        "key": AIToolProperty(type: "string", description: "Уникальный ключ/тема для удаления"),
                        "targetName": AIToolProperty(type: "string", description: "Имя конкретного таргета (например, Chappie или ChappieCore) для удаления памяти строго из этого таргета")
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
        // Это критично для безопасности — Чаппи не должен читать/писать файлы
        // когда пользователь ведёт "свободный чат" без привязанного проекта.
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

            // MARK: - Долгосрочная память

            case "memorize":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let key = args["key"],
                      let type = args["type"],
                      let jsonString = args["jsonString"] else {
                    return "Ошибка: Неверные аргументы для memorize"
                }
                let scopeString = args["scope"] ?? "project"
                let scope = MemoryScope(rawValue: scopeString) ?? .project
                let targetName = args["targetName"]
                await memoryManager.saveMemory(key: key, type: type, jsonString: jsonString, scope: scope, targetName: targetName)
                return "Успешно: Запись \(key) сохранена в памяти \(targetName != nil ? "таргета \(targetName!)" : "проекта")."

            case "recall":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let key = args["key"] else {
                    return "Ошибка: Неверные аргументы для recall"
                }
                let targetName = args["targetName"]
                if let record = await memoryManager.readMemory(key: key, targetName: targetName) {
                    return record
                } else {
                    return "Запись по ключу \(key) не найдена в памяти \(targetName != nil ? "таргета \(targetName!)" : "проекта")."
                }

            case "search_memory":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let type = args["type"] else {
                    return "Ошибка: Неверные аргументы для search_memory"
                }
                let targetName = args["targetName"]
                let results = await memoryManager.searchMemory(type: type, targetName: targetName)
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                let data = try encoder.encode(results)
                return String(data: data, encoding: .utf8) ?? "{}"

            case "delete_memory":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let key = args["key"] else {
                    return "Ошибка: Неверные аргументы для delete_memory"
                }
                let targetName = args["targetName"]
                await memoryManager.deleteMemory(key: key, targetName: targetName)
                return "Успешно: Запись \(key) удалена из памяти \(targetName != nil ? "таргета \(targetName!)" : "проекта")."

            // MARK: - MCP: Git инструменты
            // Все git-инструменты делегируются в MCPToolBridge → ChappieMCP сервер.
            // Аргументы парсим из JSON, передаём как [String: String] словарь.

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
            //
            // ПОЧЕМУ ЧЕРЕЗ CALLBACK, А НЕ НАПРЯМУЮ:
            // ToolExecutionService создаётся при выборе воркспейса — до подключения ModelContainer.
            // ProjectStore/ThreadStore создаются позже через setModelContainer().
            // Closure-обработчики регистрируются ViewModel когда все зависимости готовы.
            // Это классический паттерн "поздней привязки" (late binding) через DI.

            case "add_project_to_thread":
                // Извлекаем имя проекта из аргументов
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let displayName = args["display_name"], !displayName.isEmpty else {
                    return "Ошибка: Аргумент 'display_name' обязателен для add_project_to_thread"
                }

                // Проверяем что обработчик зарегистрирован
                guard let handler = addProjectHandler else {
                    return "Ошибка: Инструменты управления проектами недоступны. Проверьте что ModelContainer подключён (setModelContainer вызван)."
                }

                return await handler(displayName)

            case "remove_project_from_thread":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let displayName = args["display_name"], !displayName.isEmpty else {
                    return "Ошибка: Аргумент 'display_name' обязателен для remove_project_from_thread"
                }

                guard let handler = removeProjectHandler else {
                    return "Ошибка: Инструменты управления проектами недоступны. Проверьте что ModelContainer подключён (setModelContainer вызван)."
                }

                return await handler(displayName)

            case "list_thread_projects":
                guard let handler = listProjectsHandler else {
                    return "Ошибка: Инструменты управления проектами недоступны. Проверьте что ModelContainer подключён (setModelContainer вызван)."
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
