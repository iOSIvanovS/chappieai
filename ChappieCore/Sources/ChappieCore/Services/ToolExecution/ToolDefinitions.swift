// ToolDefinitions.swift
// ChappieCore
//
// WHY THIS FILE:
// All AITool definitions exposed to the AI model.
// Separated from execution logic to keep tool metadata easy to scan and update.
//
// TOOL ORDER MATTERS: LLMs tend to reach for tools listed first.
// Specialized tools (file system, memory, git, build) are listed before terminal tools.
// run_terminal and run_ssh are intentionally last — tools of last resort.
//
// UNIFIED "project" PARAMETER:
// Every tool that operates within a project scope carries a "project" display name arg.
// This is the single source of truth for access control — no path heuristics, no guessing.
// Access control in ToolAccessControl.swift resolves settings via args["project"] only.
// Exceptions: fetch_attachment / send_attachment (work with thread attachments, no project scope),
//             run_ssh (remote host).
//
// ATTACHMENT TOOLS:
// fetch_attachment — reads a user/AI attachment by UUID. No project scope.
// send_attachment  — saves AI-generated file to AttachmentStore, attaches to AI message. No project scope.
// attach_file      — legacy, kept for backward compat. Use send_attachment for new work.
//
// INJECTION RULES:
// - Universal tools (file, memory, web, project mgmt) — always injected.
// - read_document / write_document — always injected (work for any project type).
// - fetch_attachment / send_attachment — always injected (thread-level, no project needed).
// - attach_file — always injected (legacy).
// - Git tools — only if any attached project has isProgrammingProject = true.
// - build_project, run_tests, read_build_log — if any programming project is attached.
//   Each call carries a "project" arg; MCP routes to the correct env per project.
// - loc_* — only if at least one Xcode project is attached.
// - run_terminal — only if any programming project has terminal access enabled.
//   "project" arg makes every call self-contained: auto-prefixes `cd /absolute/path && command`.
// - run_ssh — only if any programming project has terminal access enabled.
//   Stateless SSH: one command per call, one connection per call.
// - git_diff is intentionally OMITTED: it dumps the entire project into AI context (cost + noise).
//
// MULTI-PROJECT NOTE:
// Tool availability is based on the union of all attached projects' settings.
// Access control per call is resolved in ToolAccessControl.swift using the "project" arg.
// WHY UNION: if any project is Executor with git, git tools must appear in the tool list.
// Blocking happens at execution time, not at injection time.

import Foundation

extension ToolExecutionService {

    /// Filtered list of tools available to the AI agent based on active project settings.
    public var availableTools: [AITool] {
        let allProjectInfos = activeMemoryContext.projects

        // Derive capabilities from the UNION of all attached projects.
        // WHY: tool list must include tools for any project that supports them.
        // Per-call access control is enforced in checkToolAccess(toolName:projectName:).
        let anyProg = allProjectInfos.contains {
            (projectSettingsCache[$0.id] ?? ProjectSettings()).isProgrammingProject
        }
        let anyTerminalEnabled = allProjectInfos.contains {
            let s = projectSettingsCache[$0.id] ?? ProjectSettings()
            return s.isProgrammingProject && s.terminalAccess.isEnabled
        }

        let progInfos = allProjectInfos.filter {
            (projectSettingsCache[$0.id] ?? ProjectSettings()).isProgrammingProject
        }

        // WHY independent of anyProg: loc_* depend on devEnvironment == .xcode across ALL
        // attached projects, not just the first one.
        let hasXcodeProject = allProjectInfos.contains {
            let s = projectSettingsCache[$0.id] ?? ProjectSettings()
            return s.isProgrammingProject && s.devEnvironment == .xcode
        }

        var tools: [AITool] = []

        // MARK: - File system (always)

        // "project" arg scopes the call to one project and is used for access control.
        // Required when multiple projects are attached; optional for single-project threads.
        tools.append(AITool(function: AIFunctionDefinition(
            name: "list_files",
            description: "Get the list of all files in the project (relative paths).",
            parameters: AIToolParameters(
                properties: [
                    "project": AIToolProperty(
                        type: "string",
                        description: listFilesProjectArgDescription(for: allProjectInfos)
                    )
                ],
                required: allProjectInfos.count > 1 ? ["project"] : []
            )
        )))

        tools.append(AITool(function: AIFunctionDefinition(
            name: "read_file",
            description: "Read the contents of a file in the project.",
            parameters: AIToolParameters(
                properties: [
                    "path": AIToolProperty(type: "string", description: "Relative path to the file"),
                    "project": AIToolProperty(
                        type: "string",
                        description: fileToolProjectArgDescription(for: allProjectInfos)
                    )
                ],
                required: allProjectInfos.count > 1 ? ["path", "project"] : ["path"]
            )
        )))

        tools.append(AITool(function: AIFunctionDefinition(
            name: "write_file",
            description: "Create a new file or fully overwrite an existing one (subdirectories are created automatically).",
            parameters: AIToolParameters(
                properties: [
                    "path": AIToolProperty(type: "string", description: "Relative path to the file"),
                    "content": AIToolProperty(type: "string", description: "Full code or text to write into the file"),
                    "project": AIToolProperty(
                        type: "string",
                        description: fileToolProjectArgDescription(for: allProjectInfos)
                    )
                ],
                required: allProjectInfos.count > 1 ? ["path", "content", "project"] : ["path", "content"]
            )
        )))

        tools.append(AITool(function: AIFunctionDefinition(
            name: "delete_file",
            description: "Delete a file from the project.",
            parameters: AIToolParameters(
                properties: [
                    "path": AIToolProperty(type: "string", description: "Relative path to the file to delete"),
                    "project": AIToolProperty(
                        type: "string",
                        description: fileToolProjectArgDescription(for: allProjectInfos)
                    )
                ],
                required: allProjectInfos.count > 1 ? ["path", "project"] : ["path"]
            )
        )))

        // MARK: - Office document tools (always)

        tools.append(AITool(function: AIFunctionDefinition(
            name: "read_document",
            description: """
            Read an Office document (Word, Excel, PowerPoint, PDF, etc.) and return its full content as XML or text.
            Use exactly like read_file — get complete content, understand the structure, then decide what to change.
            Supported formats: .docx, .xlsx, .pptx, .odt (XML-based ZIP), .rtf, .csv (plain text), .pdf (text extraction).
            For .docx/.xlsx/.pptx — returns the primary XML entry (word/document.xml, sheet1.xml, slide*.xml).
            XML preserves all formatting and structure. You can read, analyze, and prepare edits based on it.
            """,
            parameters: AIToolParameters(
                properties: [
                    "path": AIToolProperty(type: "string", description: "Relative path to the document file (e.g. 'contract.docx', 'report.xlsx')"),
                    "project": AIToolProperty(
                        type: "string",
                        description: fileToolProjectArgDescription(for: allProjectInfos)
                    )
                ],
                required: allProjectInfos.count > 1 ? ["path", "project"] : ["path"]
            )
        )))

        tools.append(AITool(function: AIFunctionDefinition(
            name: "write_document",
            description: """
            Save modified content back to an Office document.
            Use exactly like write_file — provide the full modified XML or text content.
            For ZIP-based formats (.docx, .xlsx, .pptx, .odt): replaces only the primary XML entry,
            all other ZIP entries (styles, images, relationships) are preserved untouched.
            For text formats (.rtf, .csv): overwrites the file directly.
            If output_path is provided — saves as a new file, original is untouched.
            If output_path is omitted — overwrites the original document.
            After saving — call send_attachment with the saved path to deliver the file to the user.
            """,
            parameters: AIToolParameters(
                properties: [
                    "path": AIToolProperty(type: "string", description: "Relative path to the original document"),
                    "content": AIToolProperty(type: "string", description: "Full modified XML (for docx/xlsx/pptx/odt) or text (for rtf/csv)"),
                    "output_path": AIToolProperty(type: "string", description: "Optional: save as a new file at this path, keeping the original untouched"),
                    "entry_name": AIToolProperty(type: "string", description: "Optional: override which ZIP entry to replace (e.g. 'ppt/slides/slide2.xml'). Defaults to the primary entry for each format."),
                    "project": AIToolProperty(
                        type: "string",
                        description: fileToolProjectArgDescription(for: allProjectInfos)
                    )
                ],
                required: allProjectInfos.count > 1 ? ["path", "content", "project"] : ["path", "content"]
            )
        )))

        // MARK: - Attachment tools (always, no "project" — thread-level scope)

        tools.append(AITool(function: AIFunctionDefinition(
            name: "fetch_attachment",
            description: """
            Read a file attachment from the current thread by its UUID.
            Use when the user has sent you a file and you want to read its contents.
            Returns: base64 data URI for images, XML for Office documents (docx/xlsx/pptx),
            extracted text for PDFs, UTF-8 string for plain text files.
            The UUID is shown in the attachment reference block: [Attachment: filename | uuid: ...]
            """,
            parameters: AIToolParameters(
                properties: [
                    "uuid": AIToolProperty(type: "string", description: "UUID of the attachment to fetch (from the attachment reference block)")
                ],
                required: ["uuid"]
            )
        )))

        tools.append(AITool(function: AIFunctionDefinition(
            name: "send_attachment",
            description: """
            Save a file and attach it to the current AI message so the user receives it as a downloadable bubble.
            Use after preparing file content (e.g. modifying a document) to deliver the result to the user.
            For Office documents (docx/xlsx/pptx): provide source_uuid of the original file — the tool patches
            the existing ZIP (preserving styles, images, relationships) and saves as a new file.
            For images: provide base64-encoded content (with or without data URI prefix).
            For text files: provide plain UTF-8 content.
            The user will see a chip with the filename and can open or save the file.
            """,
            parameters: AIToolParameters(
                properties: [
                    "filename": AIToolProperty(type: "string", description: "Filename with extension (e.g. 'Plan_updated.docx', 'report.xlsx')"),
                    "content": AIToolProperty(type: "string", description: "File content: XML for Office docs, base64 for images, UTF-8 for text"),
                    "mime_type": AIToolProperty(type: "string", description: "MIME type of the file (e.g. 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'image/png', 'text/plain')"),
                    "source_uuid": AIToolProperty(type: "string", description: "Optional: UUID of the original attachment to patch (required for Office documents to preserve ZIP structure)")
                ],
                required: ["filename", "content", "mime_type"]
            )
        )))

        // attach_file: legacy — kept for backward compat. Prefer send_attachment for new work.
        tools.append(AITool(function: AIFunctionDefinition(
            name: "attach_file",
            description: """
            Attach a file to the current AI message so the user receives it as a downloadable bubble.
            Use after write_document (or any file creation) to deliver the result to the user.
            The file must already exist on disk at the given absolute path.
            The user will see a chip with the filename and can save it anywhere via Save As.
            """,
            parameters: AIToolParameters(
                properties: [
                    "path": AIToolProperty(type: "string", description: "Absolute path to the file on disk (e.g. '/Users/me/Downloads/plan.docx')")
                ],
                required: ["path"]
            )
        )))

        tools.append(AITool(function: AIFunctionDefinition(
            name: "web_fetch",
            description: """
            Load a web page by URL and return its text content (without HTML markup).
            Use to fetch documentation, articles, GitHub pages, and any public web resources.
            Noise (nav, header, footer, ads) is automatically removed — only meaningful content remains.
            Limit: 100,000 characters after cleanup. If the page is larger — content is truncated from the end with a note.
            """,
            parameters: AIToolParameters(
                properties: [
                    "url": AIToolProperty(type: "string", description: "Absolute URL of the page (http or https)."),
                    "selector": AIToolProperty(type: "string", description: "Optional CSS selector to extract a specific block: tag name ('article'), '.class-name', or '#element-id'. If not specified — the entire page is processed.")
                ],
                required: ["url"]
            )
        )))

        // MARK: - Long-term memory (IT-08, always)

        tools.append(AITool(function: AIFunctionDefinition(
            name: "memorize",
            description: """
            Save important information, agreement, fact, or rule to long-term memory.
            Use scope to choose the level:
              scope="global" — global memory (cross-project rules, facts about the user).
              scope="thread" — active thread memory (current task context).
              targetName="ProjectName" — specific project memory (architecture, pipelines).
            If neither scope nor targetName is set — saves to global memory.
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
        )))

        tools.append(AITool(function: AIFunctionDefinition(
            name: "recall",
            description: """
            Retrieve information from long-term memory by key.
            Use scope or targetName to specify the memory level:
              scope="global" — global memory.
              scope="thread" — active thread memory.
              targetName="ProjectName" — specific project memory.
            """,
            parameters: AIToolParameters(
                properties: [
                    "key": AIToolProperty(type: "string", description: "Unique key/topic to recall"),
                    "scope": AIToolProperty(type: "string", description: "Scope: global (default) or thread"),
                    "targetName": AIToolProperty(type: "string", description: "Name of a specific project attached to the thread to search memory strictly in that project")
                ],
                required: ["key"]
            )
        )))

        tools.append(AITool(function: AIFunctionDefinition(
            name: "search_memory",
            description: """
            Find all memory entries by a specific type.
            Use scope or targetName to specify the memory level:
              scope="global" — global memory.
              scope="thread" — active thread memory.
              targetName="ProjectName" — specific project memory.
            """,
            parameters: AIToolParameters(
                properties: [
                    "type": AIToolProperty(type: "string", description: "Data type to search for (e.g.: rule, fact)"),
                    "scope": AIToolProperty(type: "string", description: "Scope: global (default) or thread"),
                    "targetName": AIToolProperty(type: "string", description: "Name of a specific project attached to the thread to search memory strictly in that project")
                ],
                required: ["type"]
            )
        )))

        tools.append(AITool(function: AIFunctionDefinition(
            name: "delete_memory",
            description: """
            Delete a memory entry by key.
            Use scope or targetName to specify the memory level:
              scope="global" — global memory.
              scope="thread" — active thread memory.
              targetName="ProjectName" — specific project memory.
            """,
            parameters: AIToolParameters(
                properties: [
                    "key": AIToolProperty(type: "string", description: "Unique key/topic to delete"),
                    "scope": AIToolProperty(type: "string", description: "Scope: global (default) or thread"),
                    "targetName": AIToolProperty(type: "string", description: "Name of a specific project attached to the thread to delete memory strictly from that project")
                ],
                required: ["key"]
            )
        )))

        // MARK: - Git tools (any programming project)
        // git_diff is intentionally excluded — dumps entire project into context.
        // "project" arg routes each call to the correct working directory via projectPathMap.

        if anyProg {
            let gitProjectArgDesc = gitProjectArgDescription(for: progInfos)

            tools.append(AITool(function: AIFunctionDefinition(
                name: "git_status",
                description: "Show the current git repository status: modified, new, and deleted files.",
                parameters: AIToolParameters(
                    properties: [
                        "project": AIToolProperty(type: "string", description: gitProjectArgDesc)
                    ],
                    required: progInfos.count > 1 ? ["project"] : []
                )
            )))

            tools.append(AITool(function: AIFunctionDefinition(
                name: "git_add",
                description: "Add files to the staging area (prepare for commit).",
                parameters: AIToolParameters(
                    properties: [
                        "paths": AIToolProperty(type: "string", description: "Space-separated paths, or '.' for all files (default '.')"),
                        "project": AIToolProperty(type: "string", description: gitProjectArgDesc)
                    ],
                    required: progInfos.count > 1 ? ["project"] : []
                )
            )))

            tools.append(AITool(function: AIFunctionDefinition(
                name: "git_commit",
                description: "Create a git commit with the given message.",
                parameters: AIToolParameters(
                    properties: [
                        "message": AIToolProperty(type: "string", description: "Commit message"),
                        "project": AIToolProperty(type: "string", description: gitProjectArgDesc)
                    ],
                    required: progInfos.count > 1 ? ["message", "project"] : ["message"]
                )
            )))

            tools.append(AITool(function: AIFunctionDefinition(
                name: "git_push",
                description: """
                Push committed changes to the remote repository.
                Triggers CI/CD if configured (e.g. auto-deploy to VPS on push to main).
                Use after git_commit when the work is accepted and ready to deploy.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "remote": AIToolProperty(type: "string", description: "Remote name (default: 'origin')"),
                        "branch": AIToolProperty(type: "string", description: "Branch name (default: 'main')"),
                        "project": AIToolProperty(type: "string", description: gitProjectArgDesc)
                    ],
                    required: progInfos.count > 1 ? ["project"] : []
                )
            )))

            tools.append(AITool(function: AIFunctionDefinition(
                name: "git_log",
                description: "Show the history of recent commits.",
                parameters: AIToolParameters(
                    properties: [
                        "count": AIToolProperty(type: "string", description: "Number of commits to show (default 10)"),
                        "project": AIToolProperty(type: "string", description: gitProjectArgDesc)
                    ],
                    required: progInfos.count > 1 ? ["project"] : []
                )
            )))

            tools.append(AITool(function: AIFunctionDefinition(
                name: "git_reset",
                description: "Remove all files from the staging area (git reset HEAD).",
                parameters: AIToolParameters(
                    properties: [
                        "project": AIToolProperty(type: "string", description: gitProjectArgDesc)
                    ],
                    required: progInfos.count > 1 ? ["project"] : []
                )
            )))

            tools.append(AITool(function: AIFunctionDefinition(
                name: "git_revert",
                description: """
                Revert one or more commits via git revert.
                All changes are collected into a single clean commit with the given message.
                Use when you need to undo specific commits without removing them from history.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "hashes": AIToolProperty(type: "string", description: "Space-separated commit hashes to revert (e.g.: 'abc123 def456')"),
                        "message": AIToolProperty(type: "string", description: "Message for the resulting revert commit"),
                        "project": AIToolProperty(type: "string", description: gitProjectArgDesc)
                    ],
                    required: progInfos.count > 1 ? ["hashes", "message", "project"] : ["hashes", "message"]
                )
            )))

            tools.append(AITool(function: AIFunctionDefinition(
                name: "git_checkout",
                description: """
                Restore specific files from a given commit or branch.
                Use for surgical rollback of individual files without touching the rest of the code.
                Examples of ref: HEAD~1, abc123, main
                """,
                parameters: AIToolParameters(
                    properties: [
                        "ref": AIToolProperty(type: "string", description: "Commit, branch, or relative ref (e.g.: HEAD~1, abc123, main)"),
                        "paths": AIToolProperty(type: "string", description: "Space-separated file paths to restore"),
                        "project": AIToolProperty(type: "string", description: gitProjectArgDesc)
                    ],
                    required: progInfos.count > 1 ? ["ref", "paths", "project"] : ["ref", "paths"]
                )
            )))
        }

        // MARK: - Build & test tools (any programming project)

        if anyProg {
            let projectArgDesc = buildProjectArgDescription(for: progInfos)

            let buildableInfos = progInfos.filter {
                (projectSettingsCache[$0.id] ?? ProjectSettings()).devEnvironment.specificTools.contains("build_project")
            }
            if !buildableInfos.isEmpty {
                tools.append(AITool(function: AIFunctionDefinition(
                    name: "build_project",
                    description: buildProjectDescription(for: buildableInfos),
                    parameters: AIToolParameters(
                        properties: [
                            "project": AIToolProperty(type: "string", description: projectArgDesc)
                        ],
                        required: buildableInfos.count > 1 ? ["project"] : []
                    )
                )))
            }

            if !progInfos.isEmpty {
                tools.append(AITool(function: AIFunctionDefinition(
                    name: "run_tests",
                    description: runTestsDescription(for: progInfos),
                    parameters: AIToolParameters(
                        properties: [
                            "project": AIToolProperty(type: "string", description: projectArgDesc),
                            "target": AIToolProperty(
                                type: "string",
                                description: "Test target name or file/pattern. Empty = all tests."
                            )
                        ],
                        required: progInfos.count > 1 ? ["project"] : []
                    )
                )))
            }

            if !progInfos.isEmpty {
                tools.append(AITool(function: AIFunctionDefinition(
                    name: "read_build_log",
                    description: "Read the full log of the last build or test run.",
                    parameters: AIToolParameters(
                        properties: [
                            "project": AIToolProperty(type: "string", description: projectArgDesc)
                        ],
                        required: []
                    )
                )))
            }
        }

        // MARK: - Localization tools (Xcode projects only)

        if hasXcodeProject {
            tools.append(contentsOf: localizationTools())
        }

        // MARK: - Project management (read-only, always)
        // add/remove are UI-only — only the user can attach or detach projects.

        tools.append(AITool(function: AIFunctionDefinition(
            name: "list_thread_projects",
            description: "Show the list of projects attached to the current thread. Use to check which projects are already added before add/remove operations.",
            parameters: AIToolParameters(properties: [:], required: [])
        )))

        // MARK: - Terminal tools (LAST RESORT, any programming project with terminal enabled)
        // run_terminal: persistent session, "project" auto-prefixes `cd /path && command`.
        // run_ssh: stateless — one command per call. No "project" — targets a remote host.
        // Both require terminal access to be enabled in at least one project's settings.

        if anyTerminalEnabled {
            let terminalProjectArgDesc = terminalProjectArgDescription(for: progInfos)

            tools.append(AITool(function: AIFunctionDefinition(
                name: "run_terminal",
                description: """
                Execute a command in the terminal in the project's working directory.
                The session is persistent — cd commands are remembered between calls.
                ONLY WHEN NO SPECIALIZED TOOL EXISTS: use list_files/read_file for file navigation; git_* for version control; build_project/run_tests for builds.
                Use run_terminal for: running scripts, installing dependencies, CLI utilities, and operations with no dedicated tool.
                IMPORTANT: if mode is 'With confirmation' — FIRST ask the user with the exact command and reason, then call the tool.
                Dangerous commands (rm -rf /, sudo rm, mkfs, etc.) are unconditionally blocked.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "command": AIToolProperty(type: "string", description: "Shell command to execute."),
                        "timeout": AIToolProperty(type: "string", description: "Timeout in seconds (default 300). Increase for long operations (build, npm install)."),
                        "project": AIToolProperty(type: "string", description: terminalProjectArgDesc)
                    ],
                    required: ["command"]
                )
            )))

            tools.append(AITool(function: AIFunctionDefinition(
                name: "run_ssh",
                description: """
                Execute a command on a remote server via SSH.
                Use for remote server commands only. One command = one connection. No interactive input.
                IMPORTANT: stateless — do NOT rely on previous call state. Each call is a fresh connection.
                Use for: VPS diagnostics, reading logs, restarting services, checking server status.
                Dangerous commands (rm -rf /, shutdown, etc.) are unconditionally blocked.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "host": AIToolProperty(type: "string", description: "Remote host IP or domain (e.g. '185.23.34.97' or 'myserver.com')"),
                        "command": AIToolProperty(type: "string", description: "Shell command to execute on the remote host."),
                        "user": AIToolProperty(type: "string", description: "SSH username (default: current user). E.g. 'root'."),
                        "port": AIToolProperty(type: "string", description: "SSH port (default: 22)."),
                        "timeout": AIToolProperty(type: "string", description: "Connection timeout in seconds (default: 30).")
                    ],
                    required: ["host", "command"]
                )
            )))
        }

        return tools
    }

    // MARK: - Localization tool definitions

    private func localizationTools() -> [AITool] {
        let pathArg = AIToolProperty(type: "string", description: "Relative path to the .xcstrings file (e.g. 'Chappie/Localizable.xcstrings')")
        let keyArg  = AIToolProperty(type: "string", description: "Localization key string")

        return [
            AITool(function: AIFunctionDefinition(
                name: "loc_info",
                description: """
                Returns a map of all .xcstrings files in the project with per-language coverage stats.
                Use at the start of any localization session to understand current state.
                """,
                parameters: AIToolParameters(properties: [:], required: [])
            )),

            AITool(function: AIFunctionDefinition(
                name: "loc_create",
                description: "Create a new .xcstrings localization file at the given path. Standard path: 'Chappie/Localizable.xcstrings'.",
                parameters: AIToolParameters(
                    properties: [
                        "path": AIToolProperty(type: "string", description: "Relative path for the new file (e.g. 'Chappie/Localizable.xcstrings')"),
                        "sourceLanguage": AIToolProperty(type: "string", description: "Source language code (default: 'en')")
                    ],
                    required: ["path"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "loc_rename",
                description: "Rename (move) a .xcstrings file. Remember to update the file reference in Xcode project navigator.",
                parameters: AIToolParameters(
                    properties: [
                        "from": AIToolProperty(type: "string", description: "Current relative path"),
                        "to": AIToolProperty(type: "string", description: "New relative path")
                    ],
                    required: ["from", "to"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "loc_delete",
                description: "Delete a .xcstrings file. Remember to remove the reference from Xcode project navigator.",
                parameters: AIToolParameters(
                    properties: ["path": pathArg],
                    required: ["path"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "loc_add_language",
                description: "Add a target language to a .xcstrings file (or all files if path is omitted). All existing keys will be marked for translation.",
                parameters: AIToolParameters(
                    properties: [
                        "language": AIToolProperty(type: "string", description: "Language code to add (e.g. 'ru', 'de', 'zh-Hans', 'ja')"),
                        "path": AIToolProperty(type: "string", description: "Relative path to specific .xcstrings file. Omit to apply to all files.")
                    ],
                    required: ["language"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "loc_remove_language",
                description: "Remove a target language from a .xcstrings file (or all files if path is omitted). Cannot remove source language.",
                parameters: AIToolParameters(
                    properties: [
                        "language": AIToolProperty(type: "string", description: "Language code to remove"),
                        "path": AIToolProperty(type: "string", description: "Relative path to specific .xcstrings file. Omit to apply to all files.")
                    ],
                    required: ["language"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "loc_key_check",
                description: "Check translation status for a specific key across all languages. Shows value and state per language.",
                parameters: AIToolParameters(
                    properties: [
                        "key": keyArg,
                        "path": pathArg
                    ],
                    required: ["key", "path"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "loc_next_batch",
                description: """
                Returns the next batch of keys needing translation.
                Batch size = 100 / number of target languages — never more than 100 translations per call.
                Tracks state in /tmp so repeated calls return new keys, not the same ones.
                Call this before translating to know exactly what to translate next.
                """,
                parameters: AIToolParameters(
                    properties: ["path": pathArg],
                    required: ["path"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "loc_submit_batch",
                description: """
                Submit a batch of translations to the .xcstrings file.
                Writes translations without duplicates. Always sets state: "translated".
                translations format: JSON object {"key": {"ru": "Перевод", "de": "Übersetzung"}}
                """,
                parameters: AIToolParameters(
                    properties: [
                        "path": pathArg,
                        "translations": AIToolProperty(type: "string", description: "JSON string: {\"key\": {\"lang\": \"value\", ...}, ...}")
                    ],
                    required: ["path", "translations"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "loc_dead_keys",
                description: """
                Scans all .swift files in the project and reports which keys in the .xcstrings file
                are not referenced anywhere in code. Use to clean up unused translations.
                """,
                parameters: AIToolParameters(
                    properties: ["path": pathArg],
                    required: ["path"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "loc_add_key",
                description: "Add a new localization key with its English value. Use before submitting translations for new UI strings.",
                parameters: AIToolParameters(
                    properties: [
                        "path": pathArg,
                        "key": keyArg,
                        "value": AIToolProperty(type: "string", description: "English text for this key"),
                        "comment": AIToolProperty(type: "string", description: "Optional context comment for translators")
                    ],
                    required: ["path", "key", "value"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "loc_remove_key",
                description: "Remove a localization key and all its translations from the .xcstrings file.",
                parameters: AIToolParameters(
                    properties: [
                        "path": pathArg,
                        "key": keyArg
                    ],
                    required: ["path", "key"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "loc_rename_key",
                description: """
                Rename a localization key, preserving all existing translations.
                Use to fix raw string keys (e.g. Russian literals) to proper dot-notation keys
                without losing any translations already submitted for that key.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "path": pathArg,
                        "old_key": AIToolProperty(type: "string", description: "Current key name to rename"),
                        "new_key": AIToolProperty(type: "string", description: "New dot-notation key name (e.g. 'sidebar.title')")
                    ],
                    required: ["path", "old_key", "new_key"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "loc_rename_keys",
                description: """
                Rename multiple localization keys in a single operation, preserving all translations.
                PREFER THIS over calling loc_rename_key repeatedly — the file is loaded once and saved once.
                Use to batch-fix raw string keys (Russian literals etc.) to proper dot-notation keys.
                renames format: JSON array [{"old_key": "...", "new_key": "sidebar.title"}, ...]
                Up to 100 renames per call.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "path": pathArg,
                        "renames": AIToolProperty(
                            type: "string",
                            description: "JSON array: [{\"old_key\": \"...\", \"new_key\": \"...\"}, ...]"
                        )
                    ],
                    required: ["path", "renames"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "loc_list_keys",
                description: """
                List all keys in a .xcstrings file with their English values.
                Keys that look like raw strings (non dot-notation) are marked with ⚠️.
                Use filter to narrow results by substring (e.g. filter: 'sidebar').
                Essential for auditing before batch rename operations.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "path": pathArg,
                        "filter": AIToolProperty(type: "string", description: "Optional substring filter — only keys containing this string are returned")
                    ],
                    required: ["path"]
                )
            ))
        ]
    }

    // MARK: - Dynamic tool descriptions

    private func listFilesProjectArgDescription(for infos: [ActiveMemoryContext.ProjectInfo]) -> String {
        guard !infos.isEmpty else {
            return "Project display name to scope the file listing."
        }
        if infos.count == 1 {
            return "Project name. Only one project: '\(infos[0].name)'. Can be omitted."
        }
        let list = infos.map { "'\($0.name)'" }.joined(separator: ", ")
        return "Project display name — required when multiple projects are attached. Available: \(list)."
    }

    /// Used for read_file, write_file, delete_file, read_document, write_document.
    private func fileToolProjectArgDescription(for infos: [ActiveMemoryContext.ProjectInfo]) -> String {
        guard !infos.isEmpty else {
            return "Project display name — identifies which project this file belongs to."
        }
        if infos.count == 1 {
            return "Project name. Only one project: '\(infos[0].name)'. Can be omitted."
        }
        let list = infos.map { "'\($0.name)'" }.joined(separator: ", ")
        return "Project display name — required when multiple projects are attached. Available: \(list)."
    }

    private func gitProjectArgDescription(for infos: [ActiveMemoryContext.ProjectInfo]) -> String {
        guard !infos.isEmpty else { return "Project display name to target." }
        if infos.count == 1 {
            return "Project name. Only one project: '\(infos[0].name)'. Can be omitted."
        }
        let list = infos.map { "'\($0.name)'" }.joined(separator: ", ")
        return "Project display name — required when multiple projects are attached. Available: \(list)."
    }

    private func buildProjectArgDescription(for infos: [ActiveMemoryContext.ProjectInfo]) -> String {
        guard !infos.isEmpty else { return "Project display name to target." }
        if infos.count == 1 {
            let env = (projectSettingsCache[infos[0].id] ?? ProjectSettings()).devEnvironment
            return "Project name. Only one project: '\(infos[0].name)' (\(env.displayName)). Can be omitted."
        }
        let list = infos.map { info -> String in
            let env = (projectSettingsCache[info.id] ?? ProjectSettings()).devEnvironment
            return "'\(info.name)' (\(env.displayName))"
        }.joined(separator: ", ")
        return "Project display name — required when multiple projects are attached. Available: \(list)."
    }

    /// WHY PATHS IN DESCRIPTION: AI needs to know which path it will cd into before calling the tool.
    private func terminalProjectArgDescription(for infos: [ActiveMemoryContext.ProjectInfo]) -> String {
        let pathMap = activeMemoryContext.projectPathMap
        guard !infos.isEmpty else {
            return "Optional project name. When provided — command is auto-prefixed with 'cd /path && '. Without it — use absolute paths manually."
        }
        if infos.count == 1 {
            let path = pathMap[infos[0].name] ?? "path not yet resolved"
            return "Optional project name. Specify '\(infos[0].name)' to auto-cd into '\(path)' before the command."
        }
        let list = infos.map { info -> String in
            let path = pathMap[info.name] ?? "path not yet resolved"
            return "'\(info.name)' → \(path)"
        }.joined(separator: ", ")
        return "Optional project name — auto-prefixes 'cd /path && ' before the command. Available: \(list). Omit to use absolute paths manually (e.g. for /tmp operations)."
    }

    private func buildProjectDescription(for infos: [ActiveMemoryContext.ProjectInfo]) -> String {
        if infos.count == 1 {
            let env = (projectSettingsCache[infos[0].id] ?? ProjectSettings()).devEnvironment
            return "Build the project via \(buildCommand(for: env)). Returns success or a list of compilation errors."
        }
        let lines = infos.map { info -> String in
            let env = (projectSettingsCache[info.id] ?? ProjectSettings()).devEnvironment
            return "  • \(info.name): \(buildCommand(for: env))"
        }.joined(separator: "\n")
        return "Build a project. Routes to the correct build tool per project:\n\(lines)\nReturns success or a list of compilation errors."
    }

    private func runTestsDescription(for infos: [ActiveMemoryContext.ProjectInfo]) -> String {
        if infos.count == 1 {
            let env = (projectSettingsCache[infos[0].id] ?? ProjectSettings()).devEnvironment
            return "Run automated tests via \(testCommand(for: env)). Specify target/pattern or leave empty for all tests."
        }
        let lines = infos.map { info -> String in
            let env = (projectSettingsCache[info.id] ?? ProjectSettings()).devEnvironment
            return "  • \(info.name): \(testCommand(for: env))"
        }.joined(separator: "\n")
        return "Run automated tests. Routes to the correct test runner per project:\n\(lines)\nSpecify target/pattern or leave empty for all tests."
    }

    private func buildCommand(for env: DevEnvironment) -> String {
        switch env {
        case .xcode:   return "xcodebuild"
        case .nodejs:  return "npm run build"
        case .go:      return "go build ./..."
        case .rust:    return "cargo build"
        case .java:    return "mvn compile / gradle build"
        case .kotlin:  return "gradle build"
        case .flutter: return "flutter build"
        case .dotnet:  return "dotnet build"
        default:       return "the project's build tool"
        }
    }

    private func testCommand(for env: DevEnvironment) -> String {
        switch env {
        case .xcode:           return "xcodebuild test"
        case .nodejs:          return "npm test"
        case .python:          return "pytest"
        case .go:              return "go test"
        case .rust:            return "cargo test"
        case .java:            return "mvn test / gradle test"
        case .kotlin:          return "gradle test"
        case .flutter:         return "flutter test"
        case .reacttypescript: return "npm test / vitest"
        case .dotnet:          return "dotnet test"
        default:               return "the project's test runner"
        }
    }
}
