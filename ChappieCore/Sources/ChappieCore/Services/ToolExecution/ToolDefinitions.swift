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
//
// INJECTION RULES:
// - Universal tools (file, memory, web, project mgmt, terminal) — always injected.
// - Git tools — only if isProgrammingProject = true.
// - Env-specific tools (build, test, loc) — only if isProgrammingProject = true AND devEnvironment != .unknown.

import Foundation

extension ToolExecutionService {

    /// Filtered list of tools available to the AI agent based on active project settings.
    /// Universal tools are always present; git and env-specific tools require programming project + env.
    public var availableTools: [AITool] {
        let settings = activeProjectSettings
        let isProg = settings.isProgrammingProject
        let env = settings.devEnvironment
        let envSpecific = Set(env.specificTools)

        var tools: [AITool] = []

        // MARK: - File system (always)

        tools.append(AITool(function: AIFunctionDefinition(
            name: "list_files",
            description: "Get the list of all files in the project (relative paths).",
            parameters: AIToolParameters(properties: [:], required: [])
        )))

        tools.append(AITool(function: AIFunctionDefinition(
            name: "read_file",
            description: "Read the contents of a file in the project.",
            parameters: AIToolParameters(
                properties: [
                    "path": AIToolProperty(type: "string", description: "Relative path to the file")
                ],
                required: ["path"]
            )
        )))

        tools.append(AITool(function: AIFunctionDefinition(
            name: "write_file",
            description: "Create a new file or fully overwrite an existing one (subdirectories are created automatically).",
            parameters: AIToolParameters(
                properties: [
                    "path": AIToolProperty(type: "string", description: "Relative path to the file"),
                    "content": AIToolProperty(type: "string", description: "Full code or text to write into the file")
                ],
                required: ["path", "content"]
            )
        )))

        tools.append(AITool(function: AIFunctionDefinition(
            name: "delete_file",
            description: "Delete a file from the project.",
            parameters: AIToolParameters(
                properties: [
                    "path": AIToolProperty(type: "string", description: "Relative path to the file to delete")
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

        // MARK: - Git tools (programming project only)

        if isProg {
            tools.append(AITool(function: AIFunctionDefinition(
                name: "git_status",
                description: "Show the current git repository status: modified, new, and deleted files.",
                parameters: AIToolParameters(properties: [:], required: [])
            )))

            tools.append(AITool(function: AIFunctionDefinition(
                name: "git_diff",
                description: "Show the content of code changes.",
                parameters: AIToolParameters(
                    properties: [
                        "staged": AIToolProperty(type: "string", description: "true — show staged changes (after git add), false — unstaged (default)")
                    ],
                    required: []
                )
            )))

            tools.append(AITool(function: AIFunctionDefinition(
                name: "git_add",
                description: "Add files to the staging area (prepare for commit).",
                parameters: AIToolParameters(
                    properties: [
                        "paths": AIToolProperty(type: "string", description: "Space-separated paths, or '.' for all files (default '.')")
                    ],
                    required: []
                )
            )))

            tools.append(AITool(function: AIFunctionDefinition(
                name: "git_commit",
                description: "Create a git commit with the given message.",
                parameters: AIToolParameters(
                    properties: [
                        "message": AIToolProperty(type: "string", description: "Commit message")
                    ],
                    required: ["message"]
                )
            )))

            tools.append(AITool(function: AIFunctionDefinition(
                name: "git_log",
                description: "Show the history of recent commits.",
                parameters: AIToolParameters(
                    properties: [
                        "count": AIToolProperty(type: "string", description: "Number of commits to show (default 10)")
                    ],
                    required: []
                )
            )))

            tools.append(AITool(function: AIFunctionDefinition(
                name: "git_reset",
                description: "Remove all files from the staging area (git reset HEAD).",
                parameters: AIToolParameters(properties: [:], required: [])
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
                        "message": AIToolProperty(type: "string", description: "Message for the resulting revert commit")
                    ],
                    required: ["hashes", "message"]
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
                        "paths": AIToolProperty(type: "string", description: "Space-separated file paths to restore")
                    ],
                    required: ["ref", "paths"]
                )
            )))
        }

        // MARK: - Build & test tools (programming project + known env only)

        if isProg && env != .unknown {
            if envSpecific.contains("build_project") {
                tools.append(AITool(function: AIFunctionDefinition(
                    name: "build_project",
                    description: buildProjectDescription(for: env),
                    parameters: AIToolParameters(properties: [:], required: [])
                )))
            }

            if envSpecific.contains("run_tests") {
                tools.append(AITool(function: AIFunctionDefinition(
                    name: "run_tests",
                    description: runTestsDescription(for: env),
                    parameters: AIToolParameters(
                        properties: [
                            "target": AIToolProperty(type: "string", description: "Test target name (e.g. 'ChappieCoreTests'). Empty = all tests.")
                        ],
                        required: []
                    )
                )))
            }

            if envSpecific.contains("read_build_log") {
                tools.append(AITool(function: AIFunctionDefinition(
                    name: "read_build_log",
                    description: "Read the full log of the last build or test run.",
                    parameters: AIToolParameters(properties: [:], required: [])
                )))
            }

            // MARK: - Localization tools (Xcode only)
            // xcstrings is an Xcode-specific format — inject only for Xcode projects.

            if env == .xcode {
                tools.append(contentsOf: localizationTools())
            }
        }

        // MARK: - Project management (IT-07, always)

        tools.append(AITool(function: AIFunctionDefinition(
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
        )))

        tools.append(AITool(function: AIFunctionDefinition(
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
        )))

        tools.append(AITool(function: AIFunctionDefinition(
            name: "list_thread_projects",
            description: "Show the list of projects attached to the current thread. Use to check which projects are already added before add/remove operations.",
            parameters: AIToolParameters(properties: [:], required: [])
        )))

        // MARK: - Terminal (LAST RESORT, always for programming projects)
        // WHY LAST: run_terminal is a universal hammer — it can do anything.
        // That's exactly why it must be the last option, not the first.
        // Always prefer specialized tools: list_files/read_file for navigation,
        // git_* for version control, build_project/run_tests for builds.
        // Use run_terminal ONLY when no specialized tool exists for the task.

        if isProg {
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
                        "timeout": AIToolProperty(type: "string", description: "Timeout in seconds (default 30). Increase for long operations (build, npm install).")
                    ],
                    required: ["command"]
                )
            )))
        }

        return tools
    }

    // MARK: - Localization tool definitions (Xcode / xcstrings)

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
            ))
        ]
    }

    // MARK: - Env-specific tool descriptions

    /// build_project description tailored to the active dev environment.
    private func buildProjectDescription(for env: DevEnvironment) -> String {
        switch env {
        case .xcode:    return "Build the Xcode project via xcodebuild. Returns success or a list of compilation errors."
        case .nodejs:   return "Build the Node.js project (npm run build). Returns success or a list of build errors."
        case .go:       return "Build the Go project (go build ./...). Returns success or a list of compilation errors."
        case .rust:     return "Build the Rust project (cargo build). Returns success or a list of compilation errors."
        case .java:     return "Build the Java project (mvn compile or gradle build). Returns success or a list of compilation errors."
        case .kotlin:   return "Build the Kotlin/Android project (gradle build). Returns success or a list of compilation errors."
        case .flutter:  return "Build the Flutter project (flutter build). Returns success or a list of build errors."
        case .dotnet:   return "Build the .NET project (dotnet build). Returns success or a list of compilation errors."
        default:        return "Build the project. Returns success or a list of build errors."
        }
    }

    /// run_tests description tailored to the active dev environment.
    private func runTestsDescription(for env: DevEnvironment) -> String {
        switch env {
        case .xcode:            return "Run automated tests via xcodebuild test. Specify target name or leave empty for all tests."
        case .nodejs:           return "Run automated tests (npm test). Specify test file/pattern or leave empty for all tests."
        case .python:           return "Run automated tests (pytest or unittest). Specify test file/pattern or leave empty for all tests."
        case .go:               return "Run automated tests (go test ./...). Specify package path or leave empty for all tests."
        case .rust:             return "Run automated tests (cargo test). Specify test name filter or leave empty for all tests."
        case .java:             return "Run automated tests (mvn test or gradle test). Specify test class or leave empty for all tests."
        case .kotlin:           return "Run automated tests (gradle test). Specify test class or leave empty for all tests."
        case .flutter:          return "Run automated tests (flutter test). Specify test file or leave empty for all tests."
        case .reacttypescript:  return "Run automated tests (npm test or vitest). Specify test file/pattern or leave empty for all tests."
        case .dotnet:           return "Run automated tests (dotnet test). Specify test project or leave empty for all tests."
        default:                return "Run automated tests. Specify target or leave empty for all tests."
        }
    }
}
