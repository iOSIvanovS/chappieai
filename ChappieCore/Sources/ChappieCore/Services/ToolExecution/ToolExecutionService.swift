// ToolExecutionService.swift
// ChappieCore
//
// Core actor: init, dependency injection, context setters, and main execute() dispatcher.
// Tool implementations are split by domain:
//   ToolDefinitions.swift   — availableTools array
//   ToolAccessControl.swift — IT-09 access check (role, git, tests, terminal)
//   MemoryTools.swift       — IT-08 scope resolution + memory execution cases
//   FileTools.swift         — file system + document tools + web_fetch
//   GitBuildTools.swift     — git + build/test execution
//   TerminalTools.swift     — persistent bash session + run_terminal execution

import Foundation

// MARK: - ScopeResolution (IT-08)

/// Maps scope from tool parameters to a string for MemoryStore.
enum ScopeResolution {
    case resolved(String)
    case failed(String)
}

// MARK: - ToolAccessResult (IT-09)

enum ToolAccessResult {
    case allowed
    case denied(String)
}

/// AI agent tool execution service.
///
/// Why actor: async file system + network ops require isolation in Swift 6.
public actor ToolExecutionService {
    // WHY var: V2 thread isolation swaps fileSystem per thread via setFileSystem().
    var fileSystem: FileSystemManager
    let memoryManager: MemoryManager
    let mcpBridge: MCPToolBridge
    let webFetch: WebFetchService?

    // MARK: - Active memory context (IT-08)

    var activeMemoryContext: ActiveMemoryContext = .empty

    var hasActiveProjects: Bool {
        activeMemoryContext.hasProjects
    }

    // MARK: - File system readiness flag

    /// False while syncFileSystemForActiveThread() is resolving bookmarks.
    var isFileSystemReady: Bool = true

    // MARK: - Project handlers (IT-07)

    var addProjectHandler: (@Sendable (String) async -> String)?
    var removeProjectHandler: (@Sendable (String) async -> String)?
    var listProjectsHandler: (@Sendable () async -> String)?

    // MARK: - Callbacks

    /// Called on MainActor when a FS tool fails for a specific project (B-05).
    var onProjectUnavailable: (@MainActor (String) -> Void)?

    /// Called on MainActor after every memorize/delete_memory to invalidate cached system prompt.
    var onMemoryChanged: (@MainActor () -> Void)?

    // MARK: - IT-09: Project settings cache

    /// Settings by project UUID — passed from ViewModel via setProjectSettings().
    var projectSettingsCache: [UUID: ProjectSettings] = [:]

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

    // MARK: - Context setters

    public func setActiveMemoryContext(_ context: ActiveMemoryContext) {
        self.activeMemoryContext = context
        if context.projects.isEmpty {
            print("[ToolExecutionService] 🔒 File tools blocked (no projects in thread)")
        } else {
            let names = context.projectNames.joined(separator: ", ")
            print("[ToolExecutionService] 🔓 File tools unlocked: \(names)")
        }
    }

    /// V2 M-09: Swaps the active FileSystemManager to point at the thread's first project.
    public func setFileSystem(_ fs: FileSystemManager) {
        self.fileSystem = fs
        print("[ToolExecutionService] 📂 FileSystem switched to: \(fs.workspaceURL.path)")
    }

    public func setFileSystemReady(_ ready: Bool) {
        self.isFileSystemReady = ready
        if ready {
            print("[ToolExecutionService] ✅ FileSystem ready — file tools unblocked")
        } else {
            print("[ToolExecutionService] ⏳ FileSystem syncing — file tools temporarily blocked")
        }
    }

    public func setProjectSettings(_ settings: [UUID: ProjectSettings]) {
        self.projectSettingsCache = settings
        print("[ToolExecutionService] ⚙️ Project settings updated (\(settings.count) projects)")
    }

    public func setOnProjectUnavailable(_ callback: @escaping @MainActor (String) -> Void) {
        self.onProjectUnavailable = callback
    }

    public func setOnMemoryChanged(_ callback: @escaping @MainActor () -> Void) {
        self.onMemoryChanged = callback
        print("[ToolExecutionService] ✅ Memory change callback registered")
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

    // MARK: - Tool execution dispatcher

    /// CHECK ORDER:
    /// 1. FS READINESS GUARD — block file/git/build tools while FileSystem is syncing.
    /// 2. PROJECT GUARD — require attached project for file/git/build/terminal tools.
    /// 3. TOOL ACCESS CHECK — check rights from ProjectSettings (IT-09).
    /// 4. Dispatch to the appropriate execution handler.
    public func execute(call: AIToolCall) async -> String {
        let name = call.function.name
        let argsData = call.function.arguments.data(using: .utf8) ?? Data()

        // Tools that require an active workspace project.
        // read_document / write_document are intentionally excluded: they operate on
        // arbitrary absolute paths (e.g. temp files from user attachments) and don't
        // need a workspace project to be active.
        let projectRequiredTools: Set<String> = [
            "list_files", "read_file", "write_file", "delete_file",
            "git_status", "git_diff", "git_add", "git_commit",
            "git_log", "git_reset", "git_revert", "git_checkout",
            "build_project", "run_tests", "read_build_log",
            "run_terminal"
        ]

        if projectRequiredTools.contains(name) && !isFileSystemReady {
            return """
            ⏳ Проекты ещё загружаются — файловые инструменты временно недоступны.
            Подожди секунду и повтори запрос. Это займёт не более нескольких секунд.
            """
        }

        if projectRequiredTools.contains(name) && !hasActiveProjects {
            return """
            ❌ Инструмент '\(name)' недоступен: к текущему треду не привязан ни один проект.

            Чтобы использовать файловые инструменты и git-команды, нужно сначала добавить проект к треду:
            • Нажми кнопку '+' в строке проектов над чатом, или
            • Скажи мне: "Добавь проект [имя папки]" — я вызову add_project_to_thread.
            """
        }

        if projectRequiredTools.contains(name) {
            let accessResult = checkToolAccess(toolName: name)
            if case .denied(let message) = accessResult {
                print("[ToolExecutionService] 🚫 Access denied for '\(name)'")
                return message
            }
        }

        do {
            switch name {
            case "list_files", "read_file", "write_file", "delete_file",
                 "read_document", "write_document", "web_fetch":
                return try await executeFileTool(name: name, argsData: argsData)

            case "memorize", "recall", "search_memory", "delete_memory":
                return try await executeMemoryTool(name: name, argsData: argsData)

            case "git_status", "git_diff", "git_add", "git_commit",
                 "git_log", "git_reset", "git_revert", "git_checkout",
                 "build_project", "run_tests", "read_build_log":
                return try await executeGitBuildTool(name: name, argsData: argsData)

            case "run_terminal":
                return try await executeTerminalTool(argsData: argsData)

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
