// ToolExecutionService.swift
// ChappieCore
//
// WHY THIS FILE:
// Core actor declaration, init, dependency injection, context setters,
// project handler registration, and the main execute() dispatcher.
//
// ARCHITECTURE OVERVIEW — see each extension file for details:
//   ToolDefinitions.swift   — availableTools array
//   ToolAccessControl.swift — IT-09 access check (role, git, tests)
//   MemoryTools.swift       — IT-08 scope resolution + memory execution cases
//   FileTools.swift         — file system + web_fetch execution
//   GitBuildTools.swift     — git + build/test execution
//
// MCP CONNECTION:
// MCPToolBridge is created with a socketPath injected via init().
// Path is computed by MCPHelperLauncher in Chappie.app (sandbox container path).
// ChappieCore has no access to MCPHelperLauncher — DI keeps dependencies clean.
//
// PROJECT MANAGEMENT TOOLS (IT-07):
// add/remove/list_thread_projects use closures registered via registerProjectHandlers().
// Closures are @Sendable — required for Swift 6 actor boundary crossing.
//
// THREE-LEVEL MEMORY (IT-08):
// memorize/recall/search_memory/delete_memory work with UUID-based scope strings.
// Scope resolution: resolveScope() in MemoryTools.swift.
//
// ACCESS CONTROL (IT-09):
// execute() checks ProjectSettings before running any file/git/build tool.
// Full check logic in ToolAccessControl.swift.
//
// FILE TOOL PROTECTION (PROJECT GUARD):
// File/git/build tools require at least one project attached to the thread.
// Checked via hasActiveProjects before checkToolAccess().
//
// FILE SYSTEM READINESS GUARD:
// File/git/build tools are blocked while syncFileSystemForActiveThread() is running.
// isFileSystemReady flag is set to false before sync starts, true after it completes.
// Prevents stale or empty FileSystemManager from answering tool calls during thread switch.
//
// IRON ENGLISH BARRIER (MEMORY-ENGLISH):
// memorize validates all fields for Cyrillic — code-level barrier, not prompt-level.
// validateMemoryEnglish() + containsCyrillic() in MemoryTools.swift.

import Foundation

// MARK: - ScopeResolution (IT-08)

/// Maps scope from tool parameters to a string for MemoryStore.
enum ScopeResolution {
    case resolved(String)
    case failed(String)
}

// MARK: - ToolAccessResult (IT-09)

/// Result of access check for a tool.
enum ToolAccessResult {
    case allowed
    case denied(String)
}

/// AI agent tool execution service.
///
/// Why actor: async file system + network ops require isolation in Swift 6.
public actor ToolExecutionService {
    // WHY var: V2 thread isolation swaps fileSystem per thread via setFileSystem().
    // V1 path sets it once in init and never changes it.
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
    /// File/git/build tools return a "please wait" message when false.
    /// Set via setFileSystemReady() from ChappieViewModel on MainActor.
    var isFileSystemReady: Bool = true

    // MARK: - Project handlers (IT-07)

    var addProjectHandler: (@Sendable (String) async -> String)?
    var removeProjectHandler: (@Sendable (String) async -> String)?
    var listProjectsHandler: (@Sendable () async -> String)?

    // MARK: - IT-09: Project settings cache

    /// Settings by project UUID — passed from ViewModel via setProjectSettings().
    ///
    /// WHY CACHE: ActiveMemoryContext contains only UUIDs/names.
    /// ProjectSettings live in SwiftData and can't be in ActiveMemoryContext directly.
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
    /// Called from assembleThreadSession() when V2 flag is ON and projects are present.
    /// On thread deactivation (no projects) — pass the global fileSystem to restore default.
    public func setFileSystem(_ fs: FileSystemManager) {
        self.fileSystem = fs
        print("[ToolExecutionService] 📂 FileSystem switched to: \(fs.workspaceURL.path)")
    }

    /// Marks whether the FileSystem is ready for tool calls.
    /// Called false before syncFileSystemForActiveThread() starts, true when it completes.
    public func setFileSystemReady(_ ready: Bool) {
        self.isFileSystemReady = ready
        if ready {
            print("[ToolExecutionService] ✅ FileSystem ready — file tools unblocked")
        } else {
            print("[ToolExecutionService] ⏳ FileSystem syncing — file tools temporarily blocked")
        }
    }

    /// IT-09: Updates project settings cache from ViewModel.
    public func setProjectSettings(_ settings: [UUID: ProjectSettings]) {
        self.projectSettingsCache = settings
        print("[ToolExecutionService] ⚙️ Project settings updated (\(settings.count) projects)")
    }

    /// Backward compatibility shim — maps names to placeholder UUIDs.
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

    // MARK: - Tool execution dispatcher

    /// Executes the specified tool and returns a string result.
    ///
    /// CHECK ORDER:
    /// 1. FS READINESS GUARD — block file/git/build tools while FileSystem is syncing.
    /// 2. PROJECT GUARD — require attached project for file/git/build tools.
    /// 3. TOOL ACCESS CHECK — check rights from ProjectSettings (IT-09).
    /// 4. Dispatch to the appropriate execution handler.
    public func execute(call: AIToolCall) async -> String {
        let name = call.function.name
        let argsData = call.function.arguments.data(using: .utf8) ?? Data()

        let projectRequiredTools: Set<String> = [
            "list_files", "read_file", "write_file", "delete_file",
            "git_status", "git_diff", "git_add", "git_commit",
            "git_log", "git_reset", "git_revert", "git_checkout",
            "build_project", "run_tests", "read_build_log"
        ]

        // FS READINESS GUARD: block file/git/build tools while FileSystem is syncing on thread switch.
        // WHY: bookmark resolution takes 100ms–1s per project; during that window FileSystemManager
        // may point at stale or empty workspace. Better to delay than to silently return wrong data.
        if projectRequiredTools.contains(name) && !isFileSystemReady {
            return """
            ⏳ Проекты ещё загружаются — файловые инструменты временно недоступны.
            Подожди секунду и повтори запрос. Это займёт не более нескольких секунд.
            """
        }

        // PROJECT GUARD: block file/git/build tools without an attached project.
        if projectRequiredTools.contains(name) && !hasActiveProjects {
            return """
            ❌ Инструмент '\(name)' недоступен: к текущему треду не привязан ни один проект.

            Чтобы использовать файловые инструменты и git-команды, нужно сначала добавить проект к треду:
            • Нажми кнопку '+' в строке проектов над чатом, или
            • Скажи мне: "Добавь проект [имя папки]" — я вызову add_project_to_thread.
            """
        }

        // IT-09: TOOL ACCESS CHECK — check rights from ProjectSettings.
        if projectRequiredTools.contains(name) {
            let accessResult = checkToolAccess(toolName: name)
            if case .denied(let message) = accessResult {
                print("[ToolExecutionService] 🚫 Access denied for '\(name)'")
                return message
            }
        }

        do {
            switch name {
            case "list_files", "read_file", "write_file", "delete_file", "web_fetch":
                return try await executeFileTool(name: name, argsData: argsData)

            case "memorize", "recall", "search_memory", "delete_memory":
                return try await executeMemoryTool(name: name, argsData: argsData)

            case "git_status", "git_diff", "git_add", "git_commit",
                 "git_log", "git_reset", "git_revert", "git_checkout",
                 "build_project", "run_tests", "read_build_log":
                return try await executeGitBuildTool(name: name, argsData: argsData)

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
