// ToolExecutionService.swift
// ChappieCore
//
// Core actor: init, dependency injection, context setters, and main execute() dispatcher.
// Tool implementations are split by domain:
//   ToolDefinitions.swift   — availableTools array
//   ToolAccessControl.swift — IT-09 access check (role, git, tests, terminal, license plan)
//   MemoryTools.swift       — IT-08 scope resolution + memory execution cases
//   FileTools.swift         — file system + document tools + attach_file + web_fetch
//   GitBuildTools.swift     — git + build/test execution
//   TerminalTools.swift     — persistent bash session (run_terminal) + stateless SSH (run_ssh)

import Foundation

// MARK: - ScopeResolution (IT-08)

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
    var fileSystem: FileSystemManager
    let memoryManager: MemoryManager
    let mcpBridge: MCPToolBridge
    let webFetch: WebFetchService?

    var activeMemoryContext: ActiveMemoryContext = .empty

    var hasActiveProjects: Bool {
        activeMemoryContext.hasProjects
    }

    var isFileSystemReady: Bool = true

    // Current license state — injected from ViewModel on every state change.
    // Used by ToolAccessControl to enforce plan-based restrictions (e.g. Starter = read-only).
    var licenseState: LicenseState = .loading

    var addProjectHandler: (@Sendable (String) async -> String)?
    var removeProjectHandler: (@Sendable (String) async -> String)?
    var listProjectsHandler: (@Sendable () async -> String)?

    var onProjectUnavailable: (@MainActor (String) -> Void)?
    var onMemoryChanged: (@MainActor () -> Void)?

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

    /// Atomically updates both the memory context and project settings in a single actor hop.
    ///
    /// WHY THIS EXISTS — race window fix:
    /// setActiveMemoryContext() + setProjectSettings() are two separate async calls.
    /// Between them, availableTools is computed with projects present but an empty
    /// projectSettingsCache — causing isProg=false and dropping all git/build tools
    /// (including git_push) from the tool list sent to the AI.
    /// This method eliminates the window by writing both in one synchronous pass.
    public func setMemoryContextAndSettings(
        context: ActiveMemoryContext,
        settings: [UUID: ProjectSettings]
    ) {
        self.activeMemoryContext = context
        self.projectSettingsCache = settings

        if context.projects.isEmpty {
            print("[ToolExecutionService] 🔒 File tools blocked (no projects in thread)")
        } else {
            let names = context.projectNames.joined(separator: ", ")
            print("[ToolExecutionService] 🔓 Context+Settings updated atomically: \(names) (\(settings.count) projects)")
        }
    }

    /// Updates the license state used for plan-based tool access control.
    public func setLicenseState(_ state: LicenseState) {
        self.licenseState = state
        print("[ToolExecutionService] 🔑 License state updated: \(state)")
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

    // MARK: - loc_* tool names

    private static let locToolNames: Set<String> = [
        "loc_info", "loc_create", "loc_rename", "loc_delete",
        "loc_add_language", "loc_remove_language", "loc_key_check",
        "loc_next_batch", "loc_submit_batch", "loc_dead_keys",
        "loc_add_key", "loc_remove_key", "loc_rename_key", "loc_rename_keys", "loc_list_keys"
    ]

    // MARK: - Tool execution dispatcher

    public func execute(call: AIToolCall) async -> String {
        let name = call.function.name
        let argsData = call.function.arguments.data(using: .utf8) ?? Data()

        // Extract "project" arg once — used by access control to resolve the correct
        // ProjectSettings in multi-project threads (fixes Advisor-blocks-Executor bug).
        let projectArg = (try? JSONDecoder().decode([String: String].self, from: argsData))?["project"]

        // Tools that require an active workspace project.
        let projectRequiredTools: Set<String> = [
            "list_files", "read_file", "write_file", "delete_file",
            "git_status", "git_diff", "git_add", "git_commit", "git_push",
            "git_log", "git_reset", "git_revert", "git_checkout",
            "build_project", "run_tests", "read_build_log",
            "run_terminal"
            // run_ssh intentionally excluded — connects to remote host, no local project needed
        ]

        if projectRequiredTools.contains(name) && !isFileSystemReady {
            return """
            ⏳ Projects are still loading — file tools are temporarily unavailable.
            Wait a moment and try again. This will take no more than a few seconds.
            """
        }

        if projectRequiredTools.contains(name) && !hasActiveProjects {
            return """
            ❌ Tool '\(name)' is unavailable: no project is attached to the current thread.

            To use file tools and git commands, add a project to the thread first:
            • Click the '+' button in the projects bar above the chat, or
            • Tell me: "Add project [folder name]" — I'll call add_project_to_thread.
            """
        }

        if projectRequiredTools.contains(name) {
            let accessResult = checkToolAccess(toolName: name, projectName: projectArg)
            if case .denied(let message) = accessResult {
                print("[ToolExecutionService] 🚫 Access denied for '\(name)'")
                return message
            }
        }

        // run_ssh has its own access check — requires terminal to be enabled.
        // No "project" arg for SSH — it targets a remote host, not a local project.
        if name == "run_ssh" {
            let accessResult = checkToolAccess(toolName: name, projectName: nil)
            if case .denied(let message) = accessResult {
                print("[ToolExecutionService] 🚫 Access denied for 'run_ssh'")
                return message
            }
        }

        do {
            switch name {
            case "list_files", "read_file", "write_file", "delete_file",
                 "read_document", "write_document", "attach_file", "web_fetch":
                return try await executeFileTool(name: name, argsData: argsData)

            case "memorize", "recall", "search_memory", "delete_memory":
                return try await executeMemoryTool(name: name, argsData: argsData)

            // WHY git_push is listed explicitly: the switch must cover every git tool name.
            // Missing git_push here caused it to fall into `default` → "Unknown tool" error,
            // forcing fallback to run_terminal even when the specialized tool was available.
            case "git_status", "git_diff", "git_add", "git_commit", "git_push",
                 "git_log", "git_reset", "git_revert", "git_checkout",
                 "build_project", "run_tests", "read_build_log":
                return try await executeGitBuildTool(name: name, argsData: argsData)

            case "run_terminal":
                return try await executeTerminalTool(argsData: argsData)

            case "run_ssh":
                return try await executeSSHTool(argsData: argsData)

            case "add_project_to_thread":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let displayName = args["display_name"], !displayName.isEmpty else {
                    return "Error: Argument 'display_name' is required for add_project_to_thread"
                }
                guard let handler = addProjectHandler else {
                    return "Error: Project management tools unavailable. Check that ModelContainer is connected."
                }
                return await handler(displayName)

            case "remove_project_from_thread":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let displayName = args["display_name"], !displayName.isEmpty else {
                    return "Error: Argument 'display_name' is required for remove_project_from_thread"
                }
                guard let handler = removeProjectHandler else {
                    return "Error: Project management tools unavailable. Check that ModelContainer is connected."
                }
                return await handler(displayName)

            case "list_thread_projects":
                guard let handler = listProjectsHandler else {
                    return "Error: Project management tools unavailable. Check that ModelContainer is connected."
                }
                return await handler()

            default:
                if Self.locToolNames.contains(name) {
                    guard let args = try? JSONDecoder().decode([String: String].self, from: argsData) else {
                        return "Error: Failed to parse arguments for \(name)"
                    }
                    return await mcpBridge.execute(tool: name, args: args)
                }
                return "Error: Unknown tool \(name)"
            }
        } catch {
            return "Error executing \(name): \(error.localizedDescription)"
        }
    }
}
