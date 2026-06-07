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
// - Universal tools (file, memory, web, project mgmt) — always injected.
// - read_document / write_document — always injected (work for any project type).
// - attach_file — always injected. Attaches any file by absolute path to the AI message.
// - Git tools — only if isProgrammingProject = true.
// - build_project, run_tests, read_build_log — if isProgrammingProject = true (any env).
//   Each call carries a "project" arg; MCP routes to the correct env per project.
// - loc_* — only if at least one Xcode project is attached (independent of isProg on first project).
// - run_terminal — only if isProgrammingProject = true.
// - git_diff is intentionally OMITTED: it dumps the entire project into AI context (cost + noise).

import Foundation

extension ToolExecutionService {

    /// Filtered list of tools available to the AI agent based on active project settings.
    public var availableTools: [AITool] {
        let settings = activeProjectSettings
        let isProg = settings.isProgrammingProject

        // Collect ProjectInfo entries that have programming project settings.
        // ProjectInfo carries id + name; settings are resolved from projectSettingsCache.
        let allProjectInfos = activeMemoryContext.projects
        let progInfos = allProjectInfos.filter {
            (projectSettingsCache[$0.id] ?? ProjectSettings()).isProgrammingProject
        }

        // WHY independent of isProg: loc_* depend on devEnvironment == .xcode across ALL
        // attached projects, not just the first one. A thread may have a non-prog first project
        // but still have an Xcode project attached — loc_* must appear in that case too.
        let hasXcodeProject = allProjectInfos.contains {
            let s = projectSettingsCache[$0.id] ?? ProjectSettings()
            return s.isProgrammingProject && s.devEnvironment == .xcode
        }

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

        // MARK: - Office document tools (always — work for any project type)

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
                    "path": AIToolProperty(type: "string", description: "Relative path to the document file (e.g. 'contract.docx', 'report.xlsx')")
                ],
                required: ["path"]
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
            After saving — call attach_file with the saved path to deliver the file to the user.
            """,
            parameters: AIToolParameters(
                properties: [
                    "path": AIToolProperty(type: "string", description: "Relative path to the original document"),
                    "content": AIToolProperty(type: "string", description: "Full modified XML (for docx/xlsx/pptx/odt) or text (for rtf/csv)"),
                    "output_path": AIToolProperty(type: "string", description: "Optional: save as a new file at this path, keeping the original untouched"),
                    "entry_name": AIToolProperty(type: "string", description: "Optional: override which ZIP entry to replace (e.g. 'ppt/slides/slide2.xml'). Defaults to the primary entry for each format.")
                ],
                required: ["path", "content"]
            )
        )))

        // MARK: - attach_file (always — deliver any file to the user as a bubble attachment)

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

        // MARK: - Git tools (programming project only)
        // git_diff is intentionally excluded — dumps entire project into context.

        if isProg {
            tools.append(AITool(function: AIFunctionDefinition(
                name: "git_status",
                description: "Show the current git repository status: modified, new, and deleted files.",
                parameters: AIToolParameters(properties: [:], required: [])
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

        // MARK: - Build & test tools (any programming project)
        // Tools are injected once; "project" arg routes each call to the correct env in MCP.
        // If only one project is attached — "project" can be omitted (MCP uses the single entry).

        if isProg {
            let projectArgDesc = buildProjectArgDescription(for: progInfos)

            // build_project: only if at least one project has a compilable environment.
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

            // run_tests: all programming projects support tests.
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

            // read_build_log: always available if any programming project is present.
            if !progInfos.isEmpty {
                tools.append(AITool(function: AIFunctionDefinition(
                    name: "read_build_log",
                    description: "Read the full log of the last build or test run.",
                    parameters: AIToolParameters(properties: [:], required: [])
                )))
            }
        }

        // MARK: - Localization tools (Xcode projects only, independent of isProg on first project)
        // WHY outside isProg block: hasXcodeProject checks ALL attached projects,
        // not just the first one. loc_* must appear whenever any Xcode project is in the thread.

        if hasXcodeProject {
            tools.append(contentsOf: localizationTools())
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

        // MARK: - Terminal (LAST RESORT, programming projects only)
        // WHY LAST: run_terminal is a universal hammer — prefer specialized tools always.

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

    // MARK: - Dynamic tool descriptions (built from ProjectInfo + settings cache)

    /// "project" parameter description listing all attached projects with their envs.
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

    /// Description for build_project listing each buildable project's build command.
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

    /// Description for run_tests listing each project's test command.
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
