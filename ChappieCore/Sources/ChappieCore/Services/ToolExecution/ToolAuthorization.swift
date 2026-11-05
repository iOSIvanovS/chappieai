// ToolAuthorization.swift
// ChappieCore
//
// Connects ToolPolicy (pure rules) to the live thread: figures out WHICH project a call targets,
// asks the policy about that project only, and hands the executor arguments in which the project
// name is canonical (exact spelling of the attached project).
//
// PROJECT RESOLUTION (in order):
//   1. explicit "project" arg — exact match, then case-insensitive; unknown name → denied with the list.
//   2. exactly one project attached → that one.
//   3. file tools only: a "ProjectName/…" path prefix (the file system routes by prefix too).
//   4. list_files / search_in_project without a project → every project (read-only, rights identical).
//   5. otherwise → denied, asking the model to name the project. Never "silently the first one".

import Foundation

// MARK: - Result

enum ToolAuthorization {
    /// `argsData` carries the canonical project name; `args` is the same content decoded.
    case allowed(argsData: Data, args: [String: String])
    case denied(String)
}

// MARK: - Authorization

extension ToolExecutionService {

    /// File tools that the FileSystemManager routes by "ProjectName/…" prefix when no project is given.
    private static let prefixRoutedTools: Set<String> = [
        "read_file", "write_file", "patch_file", "delete_file", "get_file_info",
        "move_file", "rename_file", "view_image", "search_in_file"
    ]

    /// Read-only tools that legitimately span all attached projects when none is named.
    private static let acrossProjectsTools: Set<String> = ["list_files", "search_in_project"]

    func authorize(toolName: String, argsData: Data) -> ToolAuthorization {
        let starter = licenseState.isStarterPlan
        let terminal = activeMemoryContext.threadTerminalAccess
        let curl = activeMemoryContext.curlEnabled

        guard let capability = ToolPolicy.capability(of: toolName) else {
            // Unknown or forbidden tool: denied whatever the arguments look like.
            let decision = ToolPolicy.decide(tool: toolName, project: nil, terminalAccess: terminal, isStarterPlan: starter, curlEnabled: curl)
            return finish(decision, argsData: argsData, args: [:])
        }

        // Every executor reads a flat string map, so normalise once here (30 → "30", true → "true").
        // web_fetch is the exception: it carries a nested headers object and parses the raw JSON itself.
        var args: [String: String] = [:]
        var argsData = argsData
        if toolName != "web_fetch" {
            switch ToolArguments.parse(data: argsData) {
            case .failure(let error):
                return .denied(ToolArguments.explanation(for: error, tool: toolName))
            case .success(let parsed):
                args = parsed
            }
            guard let flat = try? JSONEncoder().encode(args) else {
                return .denied("❌ Tool '\(toolName)': failed to re-encode arguments.")
            }
            argsData = flat
        }

        guard capability.needsProject else {
            // No project involved (always-on, terminal).
            let decision = ToolPolicy.decide(tool: toolName, project: nil, terminalAccess: terminal, isStarterPlan: starter, curlEnabled: curl)
            return finish(decision, argsData: argsData, args: args)
        }

        let projects = activeMemoryContext.projects
        let target: ActiveMemoryContext.ProjectInfo?

        switch resolveTarget(toolName: toolName, args: args, projects: projects) {
        case .failure(let error):
            return .denied(error.description)
        case .success(let resolved):
            target = resolved
        }

        guard let target else {
            // list_files / search_in_project across all projects: allowed if any project allows it.
            let allowedSomewhere = projects.contains {
                ToolPolicy.decide(
                    tool: toolName, project: settings(of: $0), terminalAccess: terminal, isStarterPlan: starter, curlEnabled: curl
                ).isAllowed
            }
            if allowedSomewhere { return .allowed(argsData: argsData, args: args) }
            return finish(
                ToolPolicy.decide(tool: toolName, project: nil, terminalAccess: terminal, isStarterPlan: starter, curlEnabled: curl),
                argsData: argsData,
                args: args
            )
        }

        let decision = ToolPolicy.decide(
            tool: toolName, project: settings(of: target), terminalAccess: terminal, isStarterPlan: starter, curlEnabled: curl
        )
        guard case .allowed = decision else { return finish(decision, argsData: argsData, args: args) }

        args["project"] = target.name
        guard let canonical = try? JSONEncoder().encode(args) else {
            return .denied("❌ Tool '\(toolName)': failed to re-encode arguments.")
        }
        return .allowed(argsData: canonical, args: args)
    }

    // MARK: - Exposure

    /// True when at least one attached project (or the thread itself) lets the model use this tool.
    /// The model is never shown tools it could not run anywhere.
    func isToolExposed(_ toolName: String) -> Bool {
        let starter = licenseState.isStarterPlan
        let terminal = activeMemoryContext.threadTerminalAccess
        let curl = activeMemoryContext.curlEnabled

        guard let capability = ToolPolicy.capability(of: toolName) else { return false }
        if !capability.needsProject {
            return ToolPolicy.decide(tool: toolName, project: nil, terminalAccess: terminal, isStarterPlan: starter, curlEnabled: curl).isAllowed
        }

        let projects = activeMemoryContext.projects
        if projects.isEmpty {
            // Read tools stay visible without a project so the call can explain how to attach one.
            return capability == .fileRead && !(starter && !capability.allowedOnStarter)
        }
        return projects.contains {
            ToolPolicy.decide(tool: toolName, project: settings(of: $0), terminalAccess: terminal, isStarterPlan: starter, curlEnabled: curl).isAllowed
        }
    }

    // MARK: - Helpers

    /// Settings of a project; a missing cache entry falls back to the safe default (ADVISOR).
    func settings(of project: ActiveMemoryContext.ProjectInfo) -> ProjectSettings {
        projectSettingsCache[project.id] ?? ProjectSettings()
    }

    private func finish(_ decision: ToolDecision, argsData: Data, args: [String: String]) -> ToolAuthorization {
        switch decision {
        case .allowed:
            return .allowed(argsData: argsData, args: args)
        case .denied(let message):
            return .denied(message)
        }
    }

    /// `.success(nil)` means "all projects" (read-only fan-out tools only).
    private func resolveTarget(
        toolName: String,
        args: [String: String],
        projects: [ActiveMemoryContext.ProjectInfo]
    ) -> Result<ActiveMemoryContext.ProjectInfo?, ResolutionError> {
        let names = projects.map { "'\($0.name)'" }.joined(separator: ", ")

        if let requested = args["project"]?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty {
            if let exact = projects.first(where: { $0.name == requested }) { return .success(exact) }
            let folded = projects.filter { $0.name.lowercased() == requested.lowercased() }
            if folded.count == 1 { return .success(folded[0]) }
            return .failure(ResolutionError("❌ Project '\(requested)' is not attached to this thread. Attached: \(names)."))
        }

        if projects.count == 1 { return .success(projects[0]) }
        if projects.isEmpty { return .failure(ResolutionError("❌ Tool '\(toolName)' needs a project, but none is attached.")) }

        if Self.prefixRoutedTools.contains(toolName) {
            let pathValue = args["path"] ?? args["from"] ?? ""
            if let byPrefix = projects.first(where: { pathValue == $0.name || pathValue.hasPrefix($0.name + "/") }) {
                return .success(byPrefix)
            }
        }

        if Self.acrossProjectsTools.contains(toolName) { return .success(nil) }

        return .failure(ResolutionError("""
        ❌ Tool '\(toolName)': several projects are attached, so you must say which one. \
        Pass the 'project' argument — one of: \(names).
        """))
    }

    private struct ResolutionError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}


// MARK: - LicenseState helpers

extension LicenseState {
    /// True when the active plan is Starter (read-only / Advisor-only).
    var isStarterPlan: Bool {
        if case .active(let plan, _) = self, plan == .starter { return true }
        return false
    }
}
