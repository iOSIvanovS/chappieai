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
//
// UNIFIED PROJECT ARG:
// Every tool that operates within a project scope carries an explicit "project" display name arg.
// Access control resolves settings via args["project"] — no path heuristics, no guessing.
// Exceptions: attach_file (absolute path, no project scope), run_ssh (remote host).

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
    var licenseState: LicenseState = .loading

    // list_thread_projects only — add/remove are UI-only, not available to AI.
    var listProjectsHandler: (@Sendable () async -> String)?

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
    /// WHY: setActiveMemoryContext() + setProjectSettings() are two separate async calls.
    /// Between them, availableTools could be computed with projects present but empty
    /// projectSettingsCache — causing isProg=false and dropping git/build tools from the list.
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

    public func setLicenseState(_ state: LicenseState) {
        self.licenseState = state
        print("[ToolExecutionService] 🔑 License state updated: \(state)")
    }

    public func setOnMemoryChanged(_ callback: @escaping @MainActor () -> Void) {
        self.onMemoryChanged = callback
        print("[ToolExecutionService] ✅ Memory change callback registered")
    }

    // MARK: - Project handler registration (list only)

    public func registerProjectHandlers(
        listProjects: @escaping @Sendable () async -> String
    ) {
        self.listProjectsHandler = listProjects
        print("[ToolExecutionService] ✅ Project list handler registered")
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

        let args = (try? JSONDecoder().decode([String: String].self, from: argsData)) ?? [:]
        let projectName = args["project"]

        let projectRequiredTools: Set<String> = [
            "list_files", "read_file", "write_file", "delete_file",
            "read_document", "write_document",
            "git_status", "git_diff", "git_add", "git_commit", "git_push",
            "git_log", "git_reset", "git_revert", "git_checkout",
            "build_project", "run_tests", "read_build_log",
            "run_terminal"
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
            • Drag and drop the project folder into the chat window.
            """
        }

        if projectRequiredTools.contains(name) {
            let accessResult = checkToolAccess(toolName: name, projectName: projectName)
            if case .denied(let message) = accessResult {
                print("[ToolExecutionService] 🚫 Access denied for '\(name)' (project: \(projectName ?? "nil"))")
                return message
            }
        }

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

            case "git_status", "git_diff", "git_add", "git_commit", "git_push",
                 "git_log", "git_reset", "git_revert", "git_checkout",
                 "build_project", "run_tests", "read_build_log":
                return try await executeGitBuildTool(name: name, argsData: argsData)

            case "run_terminal":
                return try await executeTerminalTool(argsData: argsData)

            case "run_ssh":
                return try await executeSSHTool(argsData: argsData)

            case "list_thread_projects":
                guard let handler = listProjectsHandler else {
                    return "Error: Project list handler unavailable."
                }
                return await handler()

            default:
                if Self.locToolNames.contains(name) {
                    return await mcpBridge.execute(tool: name, args: args)
                }
                return "Error: Unknown tool \(name)"
            }
        } catch {
            return "Error executing \(name): \(error.localizedDescription)"
        }
    }
}
