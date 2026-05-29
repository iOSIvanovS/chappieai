// ToolExecutionService.swift
// ChappieCore
//
// WHY THIS FILE:
// AI agent tool execution service. Receives a function call from the model,
// parses arguments and executes the action: file system, memory or MCP server.
//
// MCP CONNECTION ARCHITECTURE:
// MCPToolBridge is created with an explicit socketPath passed through init().
//
// WHY socketPath COMES FROM OUTSIDE, NOT HARDCODED:
// The Unix Domain Socket path is computed by MCPHelperLauncher in Chappie.app via
// FileManager.default.temporaryDirectory — a path INSIDE the sandbox container.
// ChappieCore is a separate Swift Package with no access to MCPHelperLauncher.
// So the path is injected via DI: Chappie.app knows the path → passes it to ToolExecutionService.
//
// ARCHITECTURAL DECISION — MONOPHYSITE ARCHITECTURE:
// After switching to monophysite architecture (one agent — Chappie)
// the `delegate_task` tool was fully removed. apiKey is also not needed —
// there are no sub-agents.
//
// ARCHITECTURAL DECISION — PROJECT MANAGEMENT TOOLS (IT-07):
// Tools add_project_to_thread and remove_project_from_thread allow Chappie
// to manage projects in the active thread during conversation.
//
// ARCHITECTURAL DECISION — THREE-LEVEL MEMORY (IT-08):
// Tools memorize/recall/search_memory/delete_memory work with UUID-based scope:
//   - scope="global"       → global memory (always available)
//   - scope="thread"       → active thread memory (UUID from ActiveMemoryContext.threadId)
//   - targetName="Chappie" → project memory "Chappie" (UUID from ActiveMemoryContext.projects)
//
// SCOPE MAPPING (IT-08):
// resolveScope() maps (scope, targetName) → scope string for MemoryManager:
//   - ("global", _)          → "global"
//   - ("thread", _)          → active thread UUID
//   - (_, "Chappie")         → UUID of project "Chappie" among attached ones
//   - unknown scope          → "global" (safe default)
//
// CONFLICT RESOLUTION (IT-08):
// If targetName is specified but no such project is in the thread — return error.
// Chappie must first add the project via add_project_to_thread.
//
// ARCHITECTURAL DECISION — ACCESS CONTROL (IT-09):
// execute() checks agent rights from ProjectSettings BEFORE executing tools.
// Check logic:
//   1. PROJECT GUARD: file/git/build tools require an attached project.
//   2. ADVISOR GUARD: write tools are blocked for .advisor role.
//   3. GIT GUARD: git tools are checked against GitAccessLevel.allowedTools.
//      git_diff is ALWAYS blocked — iron prohibition regardless of settings.
//   4. TESTS GUARD: run_tests/build_project are checked against TestsAccessLevel.
//   5. ARCHITECTURE GUARD: write_file for architecture.md checks architectureEnabled.
//
// PROJECT SETTINGS RESOLUTION (IT-09):
// Settings are taken from activeMemoryContext.projects — first project in thread.
// If multiple projects — use settings of first (the "main" one).
// Simplification for MVP; per-project routing can be added later.
//
// DEPENDENCY PROBLEM:
// ToolExecutionService lives in ChappieCore, and ProjectStore/ThreadStore are also in ChappieCore,
// but created and managed from Chappie.app (ChappieViewModel).
// Direct reference ToolExecutionService → ThreadStore/ProjectStore would create circular
// dependency through ViewModel and violate the dependency inversion principle.
//
// SOLUTION — CALLBACK/CLOSURE PATTERN:
// ViewModel registers async closures in ToolExecutionService via registerProjectHandlers().
// When Chappie calls a tool → ToolExecutionService calls the closure →
// ViewModel performs the operation with ProjectStore/ThreadStore → returns string result.
// This keeps dependencies clean: ChappieCore doesn't know about Chappie.app types.
//
// SENDABLE CLOSURES:
// Closures are marked @Sendable — required for Swift 6 when passing across actor boundaries.
// ViewModel captures only Sendable types (UUID, String) in these closures.
//
// ARCHITECTURAL DECISION — FILE TOOL PROTECTION (PROJECT GUARD):
// File tools (list_files, read_file, write_file, delete_file, git_*, build_*)
// must be available ONLY when at least one project is attached to the thread.
// This protects against accidental use of tools in "free chat" without context.
//
// HOW PROJECT GUARD WORKS:
// ViewModel calls setActiveMemoryContext() on every thread switch or project change.
// execute() checks activeMemoryContext.hasProjects before executing file tools.
// Memory and project management tools — always work.
//
// ARCHITECTURAL DECISION — IRON ENGLISH BARRIER IN MEMORY (MEMORY-ENGLISH):
// The memorize tool checks all incoming strings (key, type, jsonString) for Cyrillic
// characters. If found — returns a hard error requiring rewrite in English.
// This is a CODE barrier — does not depend on system prompt or memory.
// WHY CODE, NOT PROMPT:
//   - Prompt can be "forgotten" during history compression.
//   - A rule in memory disappears when user/session changes.
//   - Only code — is absolutely reliable and context-independent.
// DETECTOR: Unicode scalar range U+0400–U+04FF (basic Cyrillic).
// Checked: key, type, jsonString — all three required fields.
//
// ARCHITECTURAL DECISION — WEB FETCH TOOL:
// WebFetchService is injected via init() as an optional dependency.
// Default value is nil — for backward compatibility with existing init calls.
// When nil, web_fetch tool returns a clear error message.
// WHY OPTIONAL: avoids breaking existing ToolExecutionService initializers
// in tests and other callers that don't need web fetch.

import Foundation

// MARK: - ScopeResolution (IT-08)

/// Result of mapping scope from tool parameters to a string for MemoryStore.
private enum ScopeResolution {
    case resolved(String)
    case failed(String)
}

// MARK: - ToolAccessResult (IT-09)

/// Result of access check for a tool.
private enum ToolAccessResult {
    case allowed
    case denied(String)
}

/// AI agent tool execution service.
///
/// Why actor: async operations with file system and network require
/// proper isolation in Swift 6. Actor guarantees no data races.
public actor ToolExecutionService {
    private let fileSystem: FileSystemManager
    private let memoryManager: MemoryManager
    private let mcpBridge: MCPToolBridge

    // MARK: - Web Fetch

    /// Optional web fetch service — injected from outside to keep ChappieCore dependency-free.
    private let webFetch: WebFetchService?

    // MARK: - Active memory context (IT-08)

    private var activeMemoryContext: ActiveMemoryContext = .empty

    private var hasActiveProjects: Bool {
        activeMemoryContext.hasProjects
    }

    // MARK: - Project handlers (IT-07)

    private var addProjectHandler: (@Sendable (String) async -> String)?
    private var removeProjectHandler: (@Sendable (String) async -> String)?
    private var listProjectsHandler: (@Sendable () async -> String)?

    // MARK: - IT-09: Project settings cache

    /// Project settings by UUID — populated from activeMemoryContext via setProjectSettings().
    ///
    /// WHY CACHE:
    /// ActiveMemoryContext contains only UUID and project names (for memory mapping).
    /// Settings (ProjectSettings) are stored in SwiftData and cannot be in ActiveMemoryContext
    /// directly (circular dependency through Sendable).
    /// ViewModel passes settings separately via setProjectSettings().
    private var projectSettingsCache: [UUID: ProjectSettings] = [:]

    public init(
        fileSystem: FileSystemManager,
        memoryManager: MemoryManager,
        socketPath: String = "/tmp/com.chappie.mcp.sock",
        webFetch: WebFetchService? = nil
    ) {
        self.fileSystem = fileSystem
        self.memoryManager = memoryManager
        self.mcpBridge = MCPToolBridge(socketPath: socketPath)
        self.webFetch = webFetch
    }

    // MARK: - Active memory context update (IT-08)

    public func setActiveMemoryContext(_ context: ActiveMemoryContext) {
        self.activeMemoryContext = context
        if context.projects.isEmpty {
            print("[ToolExecutionService] 🔒 File tools blocked (no projects in thread)")
        } else {
            let names = context.projectNames.joined(separator: ", ")
            print("[ToolExecutionService] 🔓 File tools unlocked: \(names)")
        }
    }

    /// IT-09: Updates project settings cache.
    ///
    /// Called from ChappieViewModel after loading/updating projects.
    /// Passes ProjectSettings for each project in the thread.
    public func setProjectSettings(_ settings: [UUID: ProjectSettings]) {
        self.projectSettingsCache = settings
        print("[ToolExecutionService] ⚙️ Project settings updated (\(settings.count) projects)")
    }

    /// Backward compatibility — old setActiveProjectNames method (IT-07).
    public func setActiveProjectNames(_ names: [String]) {
        let projects = names.map { name in
            ActiveMemoryContext.ProjectInfo(id: UUID(), name: name)
        }
        self.activeMemoryContext = ActiveMemoryContext(
            threadId: activeMemoryContext.threadId,
            projects: projects
        )
        if names.isEmpty {
            print("[ToolExecutionService] 🔒 File tools blocked (no projects in thread)")
        } else {
            print("[ToolExecutionService] 🔓 File tools unlocked: \(names.joined(separator: ", "))")
        }
    }

    // MARK: - Project handler registration (IT-07)

    public func registerProjectHandlers(
        addProject: @escaping @Sendable (String) async -> String,
        removeProject: @escaping @Sendable (String) async -> String,
        listProjects: @escaping @Sendable () async -> String
    ) {
        self.addProjectHandler = addProject
        self.removeProjectHandler = removeProject
        self.listProjectsHandler = listProjects
        print("[ToolExecutionService] ✅ Project handlers registered")
    }

    // MARK: - IT-09: Tool access check

    /// Returns settings of the first project in the active thread.
    ///
    /// SELECTION LOGIC:
    /// If multiple projects — use settings of the first one.
    /// If settings not found in cache — return defaults (advisor, everything closed).
    private var activeProjectSettings: ProjectSettings {
        guard let firstProject = activeMemoryContext.projects.first else {
            return ProjectSettings() // default: advisor, everything closed
        }
        return projectSettingsCache[firstProject.id] ?? ProjectSettings()
    }

    /// Checks permission to execute a tool according to project settings (IT-09).
    ///
    /// CHECK ORDER:
    /// 1. Role .advisor — blocks all write/git/build tools.
    /// 2. git_diff — iron prohibition regardless of settings.
    /// 3. Git tools — checked against GitAccessLevel.allowedTools.
    /// 4. Build/tests tools — checked against TestsAccessLevel.
    /// 5. write_file/delete_file — allowed for executor (file system not restricted).
    ///
    /// - Parameter toolName: Tool name to check.
    /// - Returns: .allowed or .denied(message with hint).
    private func checkToolAccess(toolName: String) -> ToolAccessResult {
        let settings = activeProjectSettings

        // IRON PROHIBITION: git_diff is always blocked
        if toolName == "git_diff" {
            return .denied("""
            ❌ git_diff is permanently FORBIDDEN — it loads the entire project into AI context and costs real money.
            This prohibition cannot be overridden by any settings.
            Use git_status to see changed files, then read_file for specific files if needed.
            """)
        }

        // ADVISOR role — read only
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

        // EXECUTOR role — check detailed permissions
        let gitTools: Set<String> = ["git_status", "git_log", "git_add", "git_commit", "git_reset",
                                     "git_revert", "git_checkout"]
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

        // read_build_log — available if tests at least at readOnly level
        if toolName == "read_build_log" {
            if settings.isProgrammingProject && !settings.testsAccess.canReadLog {
                return .denied("""
                ❌ Tool 'read_build_log' is blocked: tests access is disabled.
                Open project settings → Tests → enable at least 'Read logs'.
                """)
            }
            return .allowed
        }

        // All other tools (list_files, read_file, write_file, delete_file, web_fetch) — allowed for executor
        return .allowed
    }

    // MARK: - Scope mapping for memory (IT-08)

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

    // MARK: - Cyrillic detector (MEMORY-ENGLISH barrier)

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

    // MARK: - Available tools

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
                name: "web_fetch",
                description: """
                Загрузить веб-страницу по URL и вернуть её текстовое содержимое (без HTML-разметки).
                Используй для получения документации, статей, GitHub-страниц и любых публичных веб-ресурсов.
                Шум (nav, header, footer, рекламные блоки) автоматически удаляется — остаётся только смысловой контент.
                Лимит: 100 000 символов после очистки. Если страница больше — контент обрезается с конца с пометкой.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "url": AIToolProperty(type: "string", description: "Абсолютный URL страницы (http или https)."),
                        "selector": AIToolProperty(type: "string", description: "Опциональный CSS-селектор для извлечения конкретного блока: имя тега ('article'), '.class-name' или '#element-id'. Если не указан — обрабатывается вся страница.")
                    ],
                    required: ["url"]
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
                name: "git_revert",
                description: """
                Откатить один или несколько коммитов через git revert.
                Все изменения собираются в один чистый коммит с заданным сообщением.
                Используй когда нужно отменить конкретные коммиты не удаляя их из истории.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "hashes": AIToolProperty(type: "string", description: "Хэши коммитов через пробел, которые нужно откатить (например: 'abc123 def456')"),
                        "message": AIToolProperty(type: "string", description: "Сообщение для результирующего коммита отката")
                    ],
                    required: ["hashes", "message"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "git_checkout",
                description: """
                Восстановить конкретные файлы из заданного коммита или ветки.
                Используй для хирургического отката отдельных файлов без затрагивания остального кода.
                Примеры ref: HEAD~1, abc123, main
                """,
                parameters: AIToolParameters(
                    properties: [
                        "ref": AIToolProperty(type: "string", description: "Коммит, ветка или относительная ссылка (например: HEAD~1, abc123, main)"),
                        "paths": AIToolProperty(type: "string", description: "Пути к файлам через пробел для восстановления")
                    ],
                    required: ["ref", "paths"]
                )
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

    // MARK: - Tool execution

    /// Executes the specified tool and returns a string result.
    ///
    /// CHECK ORDER (IT-09):
    /// 1. PROJECT GUARD — require attached project for file/git/build tools.
    /// 2. TOOL ACCESS CHECK — check rights from ProjectSettings (role, git, tests).
    /// 3. Execute the tool.
    public func execute(call: AIToolCall) async -> String {
        let name = call.function.name
        let argsData = call.function.arguments.data(using: .utf8) ?? Data()

        let projectRequiredTools: Set<String> = [
            "list_files", "read_file", "write_file", "delete_file",
            "git_status", "git_diff", "git_add", "git_commit",
            "git_log", "git_reset", "git_revert", "git_checkout",
            "build_project", "run_tests", "read_build_log"
        ]

        // PROJECT GUARD: block file/git/build tools without project in thread.
        if projectRequiredTools.contains(name) && !hasActiveProjects {
            return """
            ❌ Инструмент '\(name)' недоступен: к текущему треду не привязан ни один проект.

            Чтобы использовать файловые инструменты и git-команды, нужно сначала добавить проект к треду:
            • Нажми кнопку '+' в строке проектов над чатом, или
            • Скажи мне: "Добавь проект [имя папки]" — я вызову add_project_to_thread.
            """
        }

        // IT-09: TOOL ACCESS CHECK — check rights from ProjectSettings.
        // Executed only if project exists (after PROJECT GUARD).
        if projectRequiredTools.contains(name) {
            let accessResult = checkToolAccess(toolName: name)
            if case .denied(let message) = accessResult {
                print("[ToolExecutionService] 🚫 Access denied for '\(name)'")
                return message
            }
        }

        do {
            switch name {

            // MARK: - File system

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

            // MARK: - Web Fetch

            case "web_fetch":
                guard let service = webFetch else {
                    return "❌ web_fetch: service not available. WebFetchService was not injected into ToolExecutionService."
                }
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let url = args["url"], !url.isEmpty else {
                    return "❌ web_fetch: missing required argument 'url'."
                }
                let selector = args["selector"]
                return await service.fetch(urlString: url, selector: selector)

            // MARK: - Long-term memory (IT-08)

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

            // MARK: - MCP: Git tools

            case "git_status":
                return await mcpBridge.execute(tool: "git_status")

            case "git_diff":
                // This case should never be reached — git_diff is blocked in checkToolAccess().
                // Duplicating the block here as a safety net.
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

            case "git_revert":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let hashes = args["hashes"], !hashes.isEmpty else {
                    return "Ошибка: Аргумент 'hashes' обязателен для git_revert (хэши через пробел)"
                }
                guard let message = args["message"], !message.isEmpty else {
                    return "Ошибка: Аргумент 'message' обязателен для git_revert"
                }
                return await mcpBridge.execute(tool: "git_revert", args: ["hashes": hashes, "message": message])

            case "git_checkout":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let ref = args["ref"], !ref.isEmpty else {
                    return "Ошибка: Аргумент 'ref' обязателен для git_checkout (например: HEAD~1, abc123, main)"
                }
                guard let paths = args["paths"], !paths.isEmpty else {
                    return "Ошибка: Аргумент 'paths' обязателен для git_checkout (пути через пробел)"
                }
                return await mcpBridge.execute(tool: "git_checkout", args: ["ref": ref, "paths": paths])

            // MARK: - MCP: Build tools

            case "build_project":
                return await mcpBridge.execute(tool: "build_project")

            case "run_tests":
                let args = (try? JSONDecoder().decode([String: String].self, from: argsData)) ?? [:]
                return await mcpBridge.execute(tool: "run_tests", args: args)

            case "read_build_log":
                return await mcpBridge.execute(tool: "read_build_log")

            // MARK: - Project management in thread (IT-07)

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
