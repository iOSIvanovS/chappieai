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
// АРХИТЕКТУРНОЕ РЕШЕНИЕ — ПРОВЕРКА ПРАВ (IT-09):
// execute() проверяет права агента из ProjectSettings ПЕРЕД выполнением инструментов.
// Логика проверки:
//   1. PROJECT GUARD: файловые/git/build инструменты требуют привязанного проекта.
//   2. ADVISOR GUARD: инструменты записи заблокированы для роли .advisor.
//   3. GIT GUARD: git инструменты проверяются против GitAccessLevel.allowedTools.
//      git_diff ВСЕГДА заблокирован — железный запрет независимо от настроек.
//   4. TESTS GUARD: run_tests/build_project проверяются против TestsAccessLevel.
//   5. ARCHITECTURE GUARD: write_file для architecture.md проверяется architectureEnabled.
//
// ОПРЕДЕЛЕНИЕ НАСТРОЕК ПРОЕКТА (IT-09):
// Настройки берутся из activeMemoryContext.projects — первого проекта в треде.
// Если проектов несколько — используем настройки первого (самого "главного").
// Это упрощение для MVP; в будущем можно добавить per-project routing.
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
//
// АРХИТЕКТУРНОЕ РЕШЕНИЕ — ЖЕЛЕЗНЫЙ БАРЬЕР АНГЛИЙСКОГО ЯЗЫКА В ПАМЯТИ (MEMORY-ENGLISH):
// Инструмент memorize проверяет все входящие строки (key, type, jsonString) на наличие
// символов кириллицы. Если найдены — возвращает жёсткую ошибку с требованием переписать
// на английском. Это КОДОВЫЙ барьер — не зависит от системного промпта и памяти.
// ПОЧЕМУ ИМЕННО КОД, А НЕ ПРОМПТ:
//   - Промпт можно "забыть" при сжатии истории.
//   - Правило в памяти исчезнет при смене пользователя/сессии.
//   - Только код — абсолютно надёжен и не зависит от контекста.
// ДЕТЕКТОР: Unicode scalar range U+0400–U+04FF (основная кириллица).
// Проверяются: key, type, jsonString — все три обязательных поля.

import Foundation

// MARK: - ScopeResolution (IT-08)

/// Результат маппинга scope из параметров инструмента в строку для MemoryStore.
private enum ScopeResolution {
    case resolved(String)
    case failed(String)
}

// MARK: - ToolAccessResult (IT-09)

/// Результат проверки прав доступа к инструменту.
private enum ToolAccessResult {
    case allowed
    case denied(String)
}

/// Сервис выполнения инструментов ИИ-агента.
///
/// Зачем actor: async операции с файловой системой и сетью требуют
/// правильной изоляции в Swift 6. Actor гарантирует отсутствие гонок данных.
public actor ToolExecutionService {
    private let fileSystem: FileSystemManager
    private let memoryManager: MemoryManager
    private let mcpBridge: MCPToolBridge

    // MARK: - Активный контекст памяти (IT-08)

    private var activeMemoryContext: ActiveMemoryContext = .empty

    private var hasActiveProjects: Bool {
        activeMemoryContext.hasProjects
    }

    // MARK: - Обработчики проектов (IT-07)

    private var addProjectHandler: (@Sendable (String) async -> String)?
    private var removeProjectHandler: (@Sendable (String) async -> String)?
    private var listProjectsHandler: (@Sendable () async -> String)?

    // MARK: - IT-09: Кэш настроек проектов

    /// Настройки проектов по UUID — заполняется из activeMemoryContext через setProjectSettings().
    ///
    /// ЗАЧЕМ КЭШИРОВАТЬ:
    /// ActiveMemoryContext содержит только UUID и имена проектов (для маппинга памяти).
    /// Настройки (ProjectSettings) хранятся в SwiftData и не могут быть в ActiveMemoryContext
    /// напрямую (циклическая зависимость через Sendable).
    /// ViewModel передаёт настройки отдельно через setProjectSettings().
    private var projectSettingsCache: [UUID: ProjectSettings] = [:]

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

    public func setActiveMemoryContext(_ context: ActiveMemoryContext) {
        self.activeMemoryContext = context
        if context.projects.isEmpty {
            print("[ToolExecutionService] 🔒 Файловые инструменты заблокированы (нет проектов в треде)")
        } else {
            let names = context.projectNames.joined(separator: ", ")
            print("[ToolExecutionService] 🔓 Файловые инструменты разблокированы: \(names)")
        }
    }

    /// IT-09: Обновляет кэш настроек проектов.
    ///
    /// Вызывается из ChappieViewModel после загрузки/обновления проектов.
    /// Передаёт ProjectSettings для каждого проекта в треде.
    public func setProjectSettings(_ settings: [UUID: ProjectSettings]) {
        self.projectSettingsCache = settings
        print("[ToolExecutionService] ⚙️ Настройки проектов обновлены (\(settings.count) проектов)")
    }

    /// Обратная совместимость — старый метод setActiveProjectNames (IT-07).
    public func setActiveProjectNames(_ names: [String]) {
        let projects = names.map { name in
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

    // MARK: - IT-09: Проверка прав доступа к инструментам

    /// Возвращает настройки первого проекта в активном треде.
    ///
    /// ЛОГИКА ВЫБОРА:
    /// Если проектов несколько — используем настройки первого.
    /// Если настройки не найдены в кэше — возвращаем дефолтные (advisor, всё закрыто).
    private var activeProjectSettings: ProjectSettings {
        guard let firstProject = activeMemoryContext.projects.first else {
            return ProjectSettings() // дефолт: advisor, всё закрыто
        }
        return projectSettingsCache[firstProject.id] ?? ProjectSettings()
    }

    /// Проверяет право на выполнение инструмента согласно настройкам проекта (IT-09).
    ///
    /// ПОРЯДОК ПРОВЕРОК:
    /// 1. Роль .advisor — блокирует все инструменты записи/git/build.
    /// 2. git_diff — железный запрет независимо от настроек.
    /// 3. Git инструменты — проверяем против GitAccessLevel.allowedTools.
    /// 4. Build/tests инструменты — проверяем против TestsAccessLevel.
    /// 5. write_file/delete_file — разрешены для executor (файловая система не ограничена).
    ///
    /// - Parameter toolName: Имя инструмента для проверки.
    /// - Returns: .allowed или .denied(сообщение с подсказкой).
    private func checkToolAccess(toolName: String) -> ToolAccessResult {
        let settings = activeProjectSettings

        // ЖЕЛЕЗНЫЙ ЗАПРЕТ: git_diff всегда заблокирован
        if toolName == "git_diff" {
            return .denied("""
            ❌ git_diff is permanently FORBIDDEN — it loads the entire project into AI context and costs real money.
            This prohibition cannot be overridden by any settings.
            Use git_status to see changed files, then read_file for specific files if needed.
            """)
        }

        // Роль ADVISOR — только чтение
        if settings.agentRole == .advisor {
            let readOnlyTools: Set<String> = ["list_files", "read_file", "read_build_log"]
            if !readOnlyTools.contains(toolName) {
                return .denied("""
                ❌ Tool '\(toolName)' is blocked: current role is ADVISOR (read-only).
                ADVISOR can only use: list_files, read_file, read_build_log.
                To enable this tool: open project settings → change role to EXECUTOR.
                """)
            }
            return .allowed
        }

        // Роль EXECUTOR — проверяем детальные права
        let gitTools: Set<String> = ["git_status", "git_log", "git_add", "git_commit", "git_reset"]
        if gitTools.contains(toolName) {
            if !settings.isProgrammingProject {
                return .denied("""
                ❌ Tool '\(toolName)' requires 'Programming project' flag.
                Open project settings → enable 'Programming project'.
                """)
            }
            if !settings.gitAccess.allowedTools.contains(toolName) {
                return .denied("""
                ❌ Tool '\(toolName)' is blocked by git access level '\(settings.gitAccess.rawValue)'.
                Open project settings → Git → increase access level.
                Allowed tools at current level: \(settings.gitAccess.allowedTools.sorted().joined(separator: ", "))
                """)
            }
            return .allowed
        }

        let buildTools: Set<String> = ["build_project", "run_tests"]
        if buildTools.contains(toolName) {
            if !settings.isProgrammingProject {
                return .denied("""
                ❌ Tool '\(toolName)' requires 'Programming project' flag.
                Open project settings → enable 'Programming project'.
                """)
            }
            if !settings.testsAccess.canRun {
                if settings.testsAccess == .readOnly {
                    return .denied("""
                    ❌ Tool '\(toolName)' is blocked: tests access is 'read-only'.
                    You can read logs via read_build_log, but cannot run tests.
                    Open project settings → Tests → set to 'Run' or 'Run + Write'.
                    """)
                }
                return .denied("""
                ❌ Tool '\(toolName)' is blocked: tests access is disabled.
                Open project settings → Tests → enable test access.
                """)
            }
            return .allowed
        }

        // read_build_log — доступен если тесты хотя бы на уровне readOnly
        if toolName == "read_build_log" {
            if settings.isProgrammingProject && !settings.testsAccess.canReadLog {
                return .denied("""
                ❌ Tool 'read_build_log' is blocked: tests access is disabled.
                Open project settings → Tests → enable at least 'Read logs'.
                """)
            }
            return .allowed
        }

        // Все остальные инструменты (list_files, read_file, write_file, delete_file) — разрешены для executor
        return .allowed
    }

    // MARK: - Маппинг scope для памяти (IT-08)

    private func resolveScope(scopeParam: String?, targetName: String?) -> ScopeResolution {
        if let name = targetName, !name.isEmpty {
            if let project = activeMemoryContext.projects.first(where: { $0.name == name }) {
                return .resolved(project.id.uuidString)
            } else {
                let attached = activeMemoryContext.projectNames.isEmpty
                    ? "no attached projects"
                    : activeMemoryContext.projectNames.joined(separator: ", ")
                return .failed(
                    "Project '\(name)' not found in current thread. " +
                    "Attached projects: \(attached). " +
                    "Use add_project_to_thread to add the project first."
                )
            }
        }

        let scope = scopeParam ?? "global"
        if scope == "global" {
            return .resolved("global")
        }

        if scope == "thread" {
            if let threadId = activeMemoryContext.threadId {
                return .resolved(threadId.uuidString)
            } else {
                return .failed(
                    "No active thread. Thread memory unavailable. " +
                    "Use scope=\"global\" for global memory."
                )
            }
        }

        print("[ToolExecutionService] ⚠️ Unknown scope='\(scope)', falling back to 'global'")
        return .resolved("global")
    }

    // MARK: - Детектор кириллицы (MEMORY-ENGLISH барьер)

    private func containsCyrillic(_ string: String) -> Bool {
        return string.unicodeScalars.contains { scalar in
            (0x0400...0x04FF).contains(scalar.value)
        }
    }

    private func validateMemoryEnglish(key: String, type: String, jsonString: String) -> String? {
        var violatingFields: [String] = []
        if containsCyrillic(key) { violatingFields.append("key") }
        if containsCyrillic(type) { violatingFields.append("type") }
        if containsCyrillic(jsonString) { violatingFields.append("jsonString") }

        guard !violatingFields.isEmpty else { return nil }

        return """
        MEMORY LANGUAGE VIOLATION: Fields [\(violatingFields.joined(separator: ", "))] contain Cyrillic characters.
        RULE: ALL memory writes MUST be in English — no exceptions.
        Memory is internal thinking, not user communication. Think like an American engineer.
        ACTION REQUIRED: Rewrite the memorize call with all fields in English and try again.
        """
    }

    // MARK: - Доступные инструменты

    public var availableTools: [AITool] {
        return [
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

            AITool(function: AIFunctionDefinition(
                name: "memorize",
                description: """
                Запомнить важную информацию, договоренность, факт или правило в долгосрочную память.
                Используй scope для выбора уровня:
                  scope="global" — глобальная память (кросс-проектные правила, факты о пользователе).
                  scope="thread" — память активного треда (контекст текущей задачи).
                  targetName="ProjectName" — память конкретного проекта (архитектура, пайплайны).
                Если scope и targetName не заданы — сохраняется в глобальную память.
                IMPORTANT: ALL fields (key, type, jsonString) MUST be in English. Cyrillic is REJECTED.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "key": AIToolProperty(type: "string", description: "Unique key/topic for memorization (English only)"),
                        "type": AIToolProperty(type: "string", description: "Data type (e.g.: rule, fact, persona, project_map) (English only)"),
                        "jsonString": AIToolProperty(type: "string", description: "Data in JSON string format (English only)"),
                        "scope": AIToolProperty(type: "string", description: "Scope: global (default) or thread"),
                        "targetName": AIToolProperty(type: "string", description: "Name of a specific project attached to the thread (e.g., Chappie or ChappieCore) to save memory strictly in that project")
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
    /// ПОРЯДОК ПРОВЕРОК (IT-09):
    /// 1. PROJECT GUARD — требуем привязанного проекта для файловых/git/build инструментов.
    /// 2. TOOL ACCESS CHECK — проверяем права из ProjectSettings (роль, git, тесты).
    /// 3. Выполняем инструмент.
    public func execute(call: AIToolCall) async -> String {
        let name = call.function.name
        let argsData = call.function.arguments.data(using: .utf8) ?? Data()

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

        // IT-09: TOOL ACCESS CHECK — проверяем права из ProjectSettings.
        // Выполняется только если есть проект (после PROJECT GUARD).
        if projectRequiredTools.contains(name) {
            let accessResult = checkToolAccess(toolName: name)
            if case .denied(let message) = accessResult {
                print("[ToolExecutionService] 🚫 Access denied for '\(name)'")
                return message
            }
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

            case "memorize":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let key = args["key"],
                      let type = args["type"],
                      let jsonString = args["jsonString"] else {
                    return "Error: Invalid arguments for memorize (required: key, type, jsonString)"
                }

                if let cyrillicError = validateMemoryEnglish(key: key, type: type, jsonString: jsonString) {
                    print("[ToolExecutionService] ❌ MEMORY-ENGLISH violation blocked: key='\(key)'")
                    return cyrillicError
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
                    let scopeLabel: String
                    if scopeString == "global" {
                        scopeLabel = "global memory"
                    } else if scopeString == activeMemoryContext.threadId?.uuidString {
                        scopeLabel = "thread memory"
                    } else {
                        let projectName = args["targetName"] ?? scopeString
                        scopeLabel = "project memory '\(projectName)'"
                    }
                    return "✅ Entry '\(key)' saved to \(scopeLabel)."
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
                        return "Entry for key '\(key)' not found in scope '\(scopeString)'."
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
                    return "✅ Entry '\(key)' deleted from scope '\(scopeString)'."
                }

            // MARK: - MCP: Git инструменты

            case "git_status":
                return await mcpBridge.execute(tool: "git_status")

            case "git_diff":
                // Этот кейс не должен достигаться — git_diff блокируется в checkToolAccess().
                // Но на всякий случай дублируем блокировку здесь.
                return "❌ git_diff is permanently FORBIDDEN — it loads the entire project into AI context and costs real money."

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
