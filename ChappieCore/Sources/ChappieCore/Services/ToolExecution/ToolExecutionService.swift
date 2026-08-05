// ToolExecutionService.swift
// ChappieCore
//
// Core actor: init, dependency injection, context setters, and main execute() dispatcher.
// Tool implementations are split by domain:
//   ToolDefinitions.swift   — availableTools array
//   ToolAccessControl.swift — IT-09 access check (role, git, tests, terminal, license plan)
//   MemoryTools.swift       — IT-08 scope resolution + memory execution cases
//   FileTools.swift         — file system + search + document tools + attachment tools + web_fetch
//   GitBuildTools.swift     — git + build/test execution
//   TerminalTools.swift     — persistent bash session (run_terminal) + stateless SSH (run_ssh)
//
// UNIFIED PROJECT ARG:
// Every tool that operates within a project scope carries an explicit "project" display name arg.
// Access control resolves settings via args["project"] — no path heuristics, no guessing.
// Exceptions: fetch_attachment / send_attachment (thread-level, no project scope),
//             run_ssh (remote host).
//
// ATTACHMENT BRIDGE:
// AttachmentStore lives in the Chappie app target, not in ChappieCore.
// fetch_attachment / send_attachment bridge into it via injected closures:
//   resolveAttachment(uuid) -> URL?  — resolves UUID to file URL on disk
//   saveAttachment(data, filename, mimeType) -> (URL, UUID)?  — saves file, returns (url, uuid)
//   reserveAttachmentURL(filename, uuid) -> URL  — reserves URL for MCP write_document to write into
// These are registered by ChappieViewModel at startup.

import Foundation

// MARK: - AttachmentSaveResult

public struct AttachmentSaveResult: Sendable {
    public let url: URL
    public let uuid: UUID

    public init(url: URL, uuid: UUID) {
        self.url = url
        self.uuid = uuid
    }
}

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

    // MARK: - Attachment bridge closures
    // AttachmentStore lives in the app target — injected here to avoid cross-target dependency.

    /// Resolves an attachment UUID to its file URL on disk.
    var resolveAttachment: (@Sendable (UUID) -> URL?)?

    /// Saves raw data as an attachment. Returns (permanentURL, attachmentUUID) or nil on failure.
    var saveAttachment: (@Sendable (Data, String) -> AttachmentSaveResult?)?

    /// Reserves a URL in AttachmentStore for a given (filename, uuid) — used by Office doc patching.
    /// The caller (MCP write_document) writes the file to the returned URL.
    var reserveAttachmentURL: (@Sendable (String, UUID) -> URL)?

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

    // MARK: - Attachment bridge registration

    /// Registers closures that bridge fetch_attachment / send_attachment to AttachmentStore in the app target.
    public func registerAttachmentHandlers(
        resolve: @escaping @Sendable (UUID) -> URL?,
        save: @escaping @Sendable (Data, String) -> AttachmentSaveResult?,
        reserve: @escaping @Sendable (String, UUID) -> URL
    ) {
        self.resolveAttachment = resolve
        self.saveAttachment = save
        self.reserveAttachmentURL = reserve
        print("[ToolExecutionService] ✅ Attachment handlers registered")
    }

    // MARK: - Project handler registration (list only)

    public func registerProjectHandlers(
        listProjects: @escaping @Sendable () async -> String
    ) {
        self.listProjectsHandler = listProjects
        print("[ToolExecutionService] ✅ Project list handler registered")
    }

    // MARK: - view_image marker

    /// Prefix marking a view_image result as a data URI, not plain text.
    /// AIOrchestrator+ToolExecution detects this and injects a synthetic multimodal
    /// user message — the only way the model actually "sees" the image (see AIOrchestrator+ToolExecution.swift).
    public static let viewImageMarker = "__CHAPPIE_IMAGE_DATA_URI__:"

    // MARK: - loc_* tool names

    private static let locToolNames: Set<String> = [
        "loc_info", "loc_create", "loc_rename", "loc_delete",
        "loc_add_language", "loc_remove_language", "loc_key_check",
        "loc_next_batch", "loc_submit_batch", "loc_dead_keys",
        "loc_add_key", "loc_remove_key", "loc_rename_key", "loc_rename_keys", "loc_list_keys"
    ]

    // MARK: - Tool execution dispatcher

    public func execute(
        call: AIToolCall,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async -> String {
        let name = call.function.name
        let argsData = call.function.arguments.data(using: .utf8) ?? Data()

        let args = (try? JSONDecoder().decode([String: String].self, from: argsData)) ?? [:]
        let projectName = args["project"]

        let projectRequiredTools: Set<String> = [
            "list_files", "read_file", "write_file", "patch_file", "delete_file",
            "get_file_info", "move_file", "rename_file",
            "read_document", "write_document", "view_image",
            "search_in_file", "search_in_project",
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
            case "list_files", "read_file", "write_file", "patch_file", "delete_file",
                 "get_file_info", "move_file", "rename_file",
                 "read_document", "write_document",
                 "search_in_file", "search_in_project",
                 "fetch_attachment", "send_attachment", "attach_file",
                 "view_image",
                 "web_fetch":
                return try await executeFileTool(name: name, argsData: argsData)

            case "memorize", "recall", "search_memory", "delete_memory":
                return try await executeMemoryTool(name: name, argsData: argsData)

            case "git_status", "git_diff", "git_add", "git_commit", "git_push",
                 "git_log", "git_reset", "git_revert", "git_checkout",
                 "build_project", "run_tests", "read_build_log":
                return try await executeGitBuildTool(name: name, argsData: argsData)

            case "run_terminal":
                return try await executeTerminalTool(argsData: argsData, onOutput: onOutput)

            case "run_ssh":
                return try await executeSSHTool(argsData: argsData, onOutput: onOutput)

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
