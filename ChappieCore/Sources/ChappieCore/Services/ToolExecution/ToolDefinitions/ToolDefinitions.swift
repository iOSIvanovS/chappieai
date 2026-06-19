// ToolDefinitions.swift
// ChappieCore
//
// Orchestrator: assembles the final tool list from category-specific extensions.
// See ToolDefinitions+*.swift for individual tool groups.
//
// TOOL ORDER MATTERS: LLMs tend to reach for tools listed first.
// Specialized tools are listed before terminal — run_terminal/run_ssh are last resort.
//
// INJECTION RULES:
// - File, memory, document, attachment, web, project mgmt — always injected.
// - search_in_file / search_in_project / patch_file / move_file / rename_file / get_file_info
//     — when at least one project is attached.
// - Git, build, test — when any programming project is attached.
// - loc_* — when any Xcode project is attached.
// - run_terminal / run_ssh — when thread-level terminal access is enabled.
// - git_diff is intentionally OMITTED: dumps entire project into AI context.
//
// MULTI-PROJECT ACCESS CONTROL:
// Availability is based on the UNION of all attached projects' settings.
// Per-call blocking happens in ToolAccessControl.swift via the "project" arg.

import Foundation

extension ToolExecutionService {

    /// Filtered list of tools available to the AI agent based on active project settings.
    public var availableTools: [AITool] {
        let allInfos = activeMemoryContext.projects

        let anyProg = allInfos.contains {
            (projectSettingsCache[$0.id] ?? ProjectSettings()).isProgrammingProject
        }
        let anyTerminalEnabled = activeMemoryContext.threadTerminalAccess.isEnabled

        let progInfos = allInfos.filter {
            (projectSettingsCache[$0.id] ?? ProjectSettings()).isProgrammingProject
        }

        let hasXcodeProject = allInfos.contains {
            let s = projectSettingsCache[$0.id] ?? ProjectSettings()
            return s.isProgrammingProject && s.devEnvironment == .xcode
        }

        var tools: [AITool] = []

        // File system — always
        tools.append(contentsOf: fileSystemTools(allInfos: allInfos))

        // File meta, patch, move, rename, search — when projects are attached
        if !allInfos.isEmpty {
            tools.append(contentsOf: fileMetaAndEditTools(allInfos: allInfos))
            tools.append(contentsOf: searchTools(allInfos: allInfos))
        }

        // Office documents + attachments + web — always
        tools.append(contentsOf: documentTools(allInfos: allInfos))
        tools.append(contentsOf: attachmentTools())
        tools.append(AITool(function: AIFunctionDefinition(
            name: "web_fetch",
            description: "Load a web page by URL and return its text content (without HTML markup).\nUse to fetch documentation, articles, GitHub pages, and any public web resources.\nNoise (nav, header, footer, ads) is automatically removed — only meaningful content remains.\nLimit: 100,000 characters after cleanup. If the page is larger — content is truncated from the end with a note.",
            parameters: AIToolParameters(
                properties: [
                    "url": AIToolProperty(type: "string", description: "Absolute URL of the page (http or https)."),
                    "selector": AIToolProperty(type: "string", description: "Optional CSS selector to extract a specific block: tag name ('article'), '.class-name', or '#element-id'. If not specified — the entire page is processed.")
                ],
                required: ["url"]
            )
        )))

        // Memory — always
        tools.append(contentsOf: memoryTools())

        // Git — any programming project
        if anyProg {
            tools.append(contentsOf: gitTools(progInfos: progInfos))
            tools.append(contentsOf: buildTools(progInfos: progInfos, allInfos: allInfos))
        }

        // Localization — any Xcode project
        if hasXcodeProject {
            tools.append(contentsOf: localizationTools())
        }

        // Project management — always
        tools.append(contentsOf: projectManagementTools())

        // Terminal — last resort, thread-level access required
        if anyTerminalEnabled {
            tools.append(contentsOf: terminalTools(progInfos: progInfos))
        }

        return tools
    }

    // MARK: - Dynamic project arg descriptions

    func listFilesProjectArgDescription(for infos: [ActiveMemoryContext.ProjectInfo]) -> String {
        guard !infos.isEmpty else { return "Project display name to scope the file listing." }
        if infos.count == 1 { return "Project name. Only one project: '\(infos[0].name)'. Can be omitted." }
        let list = infos.map { "'\($0.name)'" }.joined(separator: ", ")
        return "Project display name — required when multiple projects are attached. Available: \(list)."
    }

    func fileToolProjectArgDescription(for infos: [ActiveMemoryContext.ProjectInfo]) -> String {
        guard !infos.isEmpty else { return "Project display name — identifies which project this file belongs to." }
        if infos.count == 1 { return "Project name. Only one project: '\(infos[0].name)'. Can be omitted." }
        let list = infos.map { "'\($0.name)'" }.joined(separator: ", ")
        return "Project display name — required when multiple projects are attached. Available: \(list)."
    }

    func gitProjectArgDescription(for infos: [ActiveMemoryContext.ProjectInfo]) -> String {
        guard !infos.isEmpty else { return "Project display name to target." }
        if infos.count == 1 { return "Project name. Only one project: '\(infos[0].name)'. Can be omitted." }
        let list = infos.map { "'\($0.name)'" }.joined(separator: ", ")
        return "Project display name — required when multiple projects are attached. Available: \(list)."
    }

    func buildProjectArgDescription(for infos: [ActiveMemoryContext.ProjectInfo]) -> String {
        guard !infos.isEmpty else { return "Project display name to target." }
        if infos.count == 1 {
            let env = (projectSettingsCache[infos[0].id] ?? ProjectSettings()).devEnvironment
            return "Project name. Only one project: '\(infos[0].name)' (\(env.displayName)). Can be omitted."
        }
        let list = infos.map { "'\($0.name)' (\((projectSettingsCache[$0.id] ?? ProjectSettings()).devEnvironment.displayName))" }.joined(separator: ", ")
        return "Project display name — required when multiple projects are attached. Available: \(list)."
    }

    // WHY PATHS IN DESCRIPTION: AI needs to know which path it will cd into before calling the tool.
    func terminalProjectArgDescription(for infos: [ActiveMemoryContext.ProjectInfo]) -> String {
        let pathMap = activeMemoryContext.projectPathMap
        guard !infos.isEmpty else {
            return "Optional project name. When provided — command is auto-prefixed with 'cd /path && '. Without it — use absolute paths manually."
        }
        if infos.count == 1 {
            let path = pathMap[infos[0].name] ?? "path not yet resolved"
            return "Optional project name. Specify '\(infos[0].name)' to auto-cd into '\(path)' before the command."
        }
        let list = infos.map { "'\($0.name)' → \(pathMap[$0.name] ?? "path not yet resolved")" }.joined(separator: ", ")
        return "Optional project name — auto-prefixes 'cd /path && ' before the command. Available: \(list). Omit to use absolute paths manually (e.g. for /tmp operations)."
    }
}
