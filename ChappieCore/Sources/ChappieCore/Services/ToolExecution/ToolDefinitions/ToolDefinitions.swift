// ToolDefinitions.swift
// ChappieCore
//
// Orchestrator: assembles the final tool list from category-specific extensions.
// See ToolDefinitions+*.swift for individual tool groups.
//
// EVERY tool is always offered. Its description starts with a status line built by ToolPolicy.status
// (always available / available in projects X / unavailable because … to enable: …), so the model knows
// its whole toolbox, why a tool is closed, and what to ask the user to switch on.
// Ordering and compression of closed tools: see ToolCatalog.
//
// The `project` argument lists ALL attached projects and is ALWAYS required (even for one project),
// exactly as ToolExecutionService.authorize demands. git_diff is offered only as FORBIDDEN.
// Per-call authorization uses the same policy against the single project the call targets.

import Foundation

extension ToolExecutionService {

    /// EVERY tool, each with its availability status; see ToolCatalog for ordering and compression.
    public var availableTools: [AITool] {
        let allInfos = activeMemoryContext.projects
        let terminal = activeMemoryContext.threadTerminalAccess
        let curl = activeMemoryContext.curlEnabled
        let statusProjects = allInfos.map { ToolStatusProject(name: $0.name, settings: settings(of: $0)) }

        let entries: [ToolCatalog.Entry] = allToolDefinitions(allInfos: allInfos).map { tool in
            let status = ToolPolicy.status(
                of: tool.function.name, projects: statusProjects, terminalAccess: terminal, curlEnabled: curl
            )
            return (tool, status)
        }
        return ToolCatalog.compose(entries)
    }

    /// Full definitions of every tool, regardless of whether it can run in this thread.
    private func allToolDefinitions(allInfos: [ActiveMemoryContext.ProjectInfo]) -> [AITool] {
        var tools: [AITool] = []

        tools.append(contentsOf: fileSystemTools(allInfos: allInfos))
        tools.append(contentsOf: fileMetaAndEditTools(allInfos: allInfos))
        tools.append(contentsOf: searchTools(allInfos: allInfos))

        // Office documents + attachments + web
        tools.append(contentsOf: documentTools(allInfos: allInfos))
        tools.append(contentsOf: pdfTools(allInfos: allInfos))
        tools.append(contentsOf: attachmentTools())
        tools.append(AITool(function: AIFunctionDefinition(
            name: "web_fetch",
            description: "Load a web page by URL and return its text content (without HTML markup).\nUse to fetch documentation, articles, GitHub pages, and any public web resources.\nNoise (nav, header, footer, ads) is automatically removed — only meaningful content remains.\nLimit: 100,000 characters after cleanup. If the page is larger — content is truncated from the end with a note.",
            parameters: AIToolParameters(
                properties: [
                    "url": AIToolProperty(type: "string", description: "Absolute URL of the page (http or https)."),
                    "selector": AIToolProperty(type: "string", description: "Optional CSS selector to extract a specific block: tag name ('article'), '.class-name', or '#element-id'. If not specified — the entire page is processed."),
                    "headers": AIToolProperty(type: "object", description: "Optional HTTP headers to include in the request (e.g. for API authentication). Example: {\"X-Figma-Token\": \"...\", \"Authorization\": \"Bearer ...\"}. Merged on top of default User-Agent — caller values win on conflict.")
                ],
                required: ["url"]
            )
        )))

        tools.append(contentsOf: memoryTools())
        tools.append(contentsOf: gitTools(allInfos: allInfos))
        tools.append(gitDiffTool())
        tools.append(contentsOf: buildTools(allInfos: allInfos))
        tools.append(contentsOf: localizationTools(allInfos: allInfos))
        tools.append(contentsOf: curlTools(allInfos: allInfos))
        tools.append(contentsOf: projectManagementTools())
        tools.append(contentsOf: terminalTools(allInfos: allInfos))
        return tools
    }

    /// Present only so the model sees it is banned and why; ToolPolicy refuses every call.
    private func gitDiffTool() -> AITool {
        AITool(function: AIFunctionDefinition(
            name: "git_diff",
            description: "Show the git diff of the working tree.",
            parameters: AIToolParameters(properties: [:], required: [])
        ))
    }

    // MARK: - Dynamic project arg descriptions

    func listFilesProjectArgDescription(for infos: [ActiveMemoryContext.ProjectInfo]) -> String {
        guard !infos.isEmpty else { return "Project display name to scope the file listing." }
        if infos.count == 1 { return "Project name. Only one project: '\(infos[0].name)'. Required." }
        let list = infos.map { "'\($0.name)'" }.joined(separator: ", ")
        return "Project display name (required). Available: \(list)."
    }

    func fileToolProjectArgDescription(for infos: [ActiveMemoryContext.ProjectInfo]) -> String {
        guard !infos.isEmpty else { return "Project display name — identifies which project this file belongs to." }
        if infos.count == 1 { return "Project name. Only one project: '\(infos[0].name)'. Required." }
        let list = infos.map { "'\($0.name)'" }.joined(separator: ", ")
        return "Project display name (required). Available: \(list)."
    }

    func gitProjectArgDescription(for infos: [ActiveMemoryContext.ProjectInfo]) -> String {
        guard !infos.isEmpty else { return "Project display name to target." }
        if infos.count == 1 { return "Project name. Only one project: '\(infos[0].name)'. Required." }
        let list = infos.map { "'\($0.name)'" }.joined(separator: ", ")
        return "Project display name (required). Available: \(list)."
    }

    func buildProjectArgDescription(for infos: [ActiveMemoryContext.ProjectInfo]) -> String {
        guard !infos.isEmpty else { return "Project display name to target." }
        if infos.count == 1 {
            let env = (projectSettingsCache[infos[0].id] ?? ProjectSettings()).devEnvironment
            return "Project name. Only one project: '\(infos[0].name)' (\(env.displayName)). Required."
        }
        let list = infos.map { "'\($0.name)' (\((projectSettingsCache[$0.id] ?? ProjectSettings()).devEnvironment.displayName))" }.joined(separator: ", ")
        return "Project display name (required). Available: \(list)."
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
