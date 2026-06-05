// ToolDefinitions.swift
// ChappieCore
//
// WHY THIS FILE:
// All AITool definitions exposed to the AI model.
// Separated from execution logic to keep tool metadata easy to scan and update.
//
// TOOL ORDER MATTERS: LLMs tend to reach for tools listed first.
// Specialized tools (file system, memory, git, build) are listed before run_terminal.
// run_terminal is intentionally last — it is the tool of last resort.

import Foundation

extension ToolExecutionService {

    /// Full list of tools available to the AI agent.
    public var availableTools: [AITool] {
        return [
            // MARK: - File system

            AITool(function: AIFunctionDefinition(
                name: "list_files",
                description: "Get the list of all files in the project (relative paths).",
                parameters: AIToolParameters(properties: [:], required: [])
            )),

            AITool(function: AIFunctionDefinition(
                name: "read_file",
                description: "Read the contents of a file in the project.",
                parameters: AIToolParameters(
                    properties: [
                        "path": AIToolProperty(type: "string", description: "Relative path to the file")
                    ],
                    required: ["path"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "write_file",
                description: "Create a new file or fully overwrite an existing one (subdirectories are created automatically).",
                parameters: AIToolParameters(
                    properties: [
                        "path": AIToolProperty(type: "string", description: "Relative path to the file"),
                        "content": AIToolProperty(type: "string", description: "Full code or text to write into the file")
                    ],
                    required: ["path", "content"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "delete_file",
                description: "Delete a file from the project.",
                parameters: AIToolParameters(
                    properties: [
                        "path": AIToolProperty(type: "string", description: "Relative path to the file to delete")
                    ],
                    required: ["path"]
                )
            )),

            AITool(function: AIFunctionDefinition(
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
            )),

            // MARK: - Long-term memory (IT-08)

            AITool(function: AIFunctionDefinition(
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
            )),

            AITool(function: AIFunctionDefinition(
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
            )),

            AITool(function: AIFunctionDefinition(
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
            )),

            AITool(function: AIFunctionDefinition(
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
            )),

            // MARK: - Git tools

            AITool(function: AIFunctionDefinition(
                name: "git_status",
                description: "Show the current git repository status: modified, new, and deleted files.",
                parameters: AIToolParameters(properties: [:], required: [])
            )),

            AITool(function: AIFunctionDefinition(
                name: "git_diff",
                description: "Show the content of code changes.",
                parameters: AIToolParameters(
                    properties: [
                        "staged": AIToolProperty(type: "string", description: "true — show staged changes (after git add), false — unstaged (default)")
                    ],
                    required: []
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "git_add",
                description: "Add files to the staging area (prepare for commit).",
                parameters: AIToolParameters(
                    properties: [
                        "paths": AIToolProperty(type: "string", description: "Space-separated paths, or '.' for all files (default '.')")
                    ],
                    required: []
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "git_commit",
                description: "Create a git commit with the given message.",
                parameters: AIToolParameters(
                    properties: [
                        "message": AIToolProperty(type: "string", description: "Commit message")
                    ],
                    required: ["message"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "git_log",
                description: "Show the history of recent commits.",
                parameters: AIToolParameters(
                    properties: [
                        "count": AIToolProperty(type: "string", description: "Number of commits to show (default 10)")
                    ],
                    required: []
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "git_reset",
                description: "Remove all files from the staging area (git reset HEAD).",
                parameters: AIToolParameters(properties: [:], required: [])
            )),

            AITool(function: AIFunctionDefinition(
                name: "git_revert",
                description: """
                Revert one or more commits via git revert.
                All changes are collected into a single clean commit with the given message.
                Use when you need to undo specific commits without removing them from history.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "hashes": AIToolProperty(type: "string", description: "Space-separated commit hashes to revert (e.g.: 'abc123 def456')"),
                        "message": AIToolProperty(type: "string", description: "Message for the resulting revert commit")
                    ],
                    required: ["hashes", "message"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "git_checkout",
                description: """
                Restore specific files from a given commit or branch.
                Use for surgical rollback of individual files without touching the rest of the code.
                Examples of ref: HEAD~1, abc123, main
                """,
                parameters: AIToolParameters(
                    properties: [
                        "ref": AIToolProperty(type: "string", description: "Commit, branch, or relative ref (e.g.: HEAD~1, abc123, main)"),
                        "paths": AIToolProperty(type: "string", description: "Space-separated file paths to restore")
                    ],
                    required: ["ref", "paths"]
                )
            )),

            // MARK: - Build & test tools

            AITool(function: AIFunctionDefinition(
                name: "build_project",
                description: "Build the Chappie.xcodeproj project via xcodebuild. Returns success or a list of compilation errors.",
                parameters: AIToolParameters(properties: [:], required: [])
            )),

            AITool(function: AIFunctionDefinition(
                name: "run_tests",
                description: "Run automated tests. ChappieCore uses swift test, Chappie.app uses xcodebuild test.",
                parameters: AIToolParameters(
                    properties: [
                        "target": AIToolProperty(type: "string", description: "Test target name (e.g. 'ChappieCoreTests'). Empty = all tests.")
                    ],
                    required: []
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "read_build_log",
                description: "Read the full log of the last build or test run.",
                parameters: AIToolParameters(properties: [:], required: [])
            )),

            // MARK: - Project management (IT-07)

            AITool(function: AIFunctionDefinition(
                name: "add_project_to_thread",
                description: "Add a project to the current thread by folder name. Use when the user asks to attach a project to the conversation or when the task clearly belongs to a specific project.",
                parameters: AIToolParameters(
                    properties: [
                        "display_name": AIToolProperty(
                            type: "string",
                            description: "Display name of the project (folder name). E.g.: 'Chappie', 'MyApp', 'Backend'. Must match the real folder name of the project."
                        )
                    ],
                    required: ["display_name"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "remove_project_from_thread",
                description: "Remove a project from the current thread by name. Use when the user asks to detach a project or the task no longer concerns this project.",
                parameters: AIToolParameters(
                    properties: [
                        "display_name": AIToolProperty(
                            type: "string",
                            description: "Display name of the project to remove from the thread. Must exactly match the name of the added project."
                        )
                    ],
                    required: ["display_name"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "list_thread_projects",
                description: "Show the list of projects attached to the current thread. Use to check which projects are already added before add/remove operations.",
                parameters: AIToolParameters(properties: [:], required: [])
            )),

            // MARK: - Terminal (LAST RESORT)
            // WHY LAST: run_terminal is a universal hammer — it can do anything.
            // That's exactly why it must be the last option, not the first.
            // Always prefer specialized tools: list_files/read_file for navigation,
            // git_* for version control, build_project/run_tests for builds.
            // Use run_terminal ONLY when no specialized tool exists for the task.

            AITool(function: AIFunctionDefinition(
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
                        "timeout": AIToolProperty(type: "string", description: "Timeout in seconds (default 30). Increase for long operations (build, npm install).")
                    ],
                    required: ["command"]
                )
            ))
        ]
    }
}
