// ToolAuthorization.swift
// ChappieCore
//
// Connects ToolPolicy (pure rules) to the live thread: figures out WHICH project a call targets,
// asks the policy about that project only, and hands the executor arguments in which the project
// name is canonical (exact spelling of the attached project).
//
// PROJECT RESOLUTION: the "project" argument is REQUIRED for every project tool, even when only one
// project is attached. One strict rule instead of behaviour that changes with the number of projects.
//   1. "project" given — exact match, then case-insensitive; unknown name → denied with the list.
//   2. "project" missing or empty → denied, asking the model to name it. Never "silently the first one".
// Paths are always relative to the project root; a "ProjectName/…" prefix is never interpreted,
// because a project may contain a folder with its own name.

import Foundation

// MARK: - Result

enum ToolAuthorization {
    /// `argsData` carries the canonical project name; `args` is the same content decoded.
    case allowed(argsData: Data, args: [String: String])
    case denied(String)
}

// MARK: - Authorization

extension ToolExecutionService {

    func authorize(toolName: String, argsData: Data) -> ToolAuthorization {
        let terminal = activeMemoryContext.threadTerminalEnabled
        let curl = activeMemoryContext.curlEnabled

        guard let capability = ToolPolicy.capability(of: toolName) else {
            // Unknown or forbidden tool: denied whatever the arguments look like.
            let decision = ToolPolicy.decide(tool: toolName, project: nil, terminalEnabled: terminal, curlEnabled: curl)
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
            let decision = ToolPolicy.decide(tool: toolName, project: nil, terminalEnabled: terminal, curlEnabled: curl)
            return finish(decision, argsData: argsData, args: args)
        }

        let projects = activeMemoryContext.projects
        let target: ActiveMemoryContext.ProjectInfo

        switch resolveTarget(toolName: toolName, args: args, projects: projects) {
        case .failure(let error):
            return .denied(error.description + whereItWorks(toolName, capability, excluding: nil, terminal: terminal, curl: curl))
        case .success(let resolved):
            target = resolved
        }

        let decision = ToolPolicy.decide(
            tool: toolName, project: settings(of: target), terminalEnabled: terminal, curlEnabled: curl
        )
        if case .denied(let message) = decision {
            let hint = whereItWorks(toolName, capability, excluding: target.name, terminal: terminal, curl: curl)
            return .denied(message + hint)
        }

        args["project"] = target.name
        guard let canonical = try? JSONEncoder().encode(args) else {
            return .denied("❌ Tool '\(toolName)': failed to re-encode arguments.")
        }
        return .allowed(argsData: canonical, args: args)
    }

    // MARK: - Helpers

    /// Settings of a project; a missing cache entry falls back to the safe default (ADVISOR).
    func settings(of project: ActiveMemoryContext.ProjectInfo) -> ProjectSettings {
        projectSettingsCache[project.id] ?? ProjectSettings()
    }

    /// Tail for a refusal: the attached projects where this very tool does work, so the model can retarget
    /// the call instead of giving up. Empty when the thread itself blocks the tool (no project helps then).
    func whereItWorks(
        _ toolName: String,
        _ capability: ToolCapability,
        excluding: String?,
        terminal: Bool,
        curl: Bool
    ) -> String {
        guard capability.needsProject,
              ToolPolicy.threadBlock(capability, terminalEnabled: terminal, curlEnabled: curl) == nil
        else { return "" }

        let projects = activeMemoryContext.projects
        guard !projects.isEmpty else {
            return "\nNo project is attached; attach one ('+' in the projects bar, or drop a folder into the chat)."
        }
        let working = projects.filter {
            $0.name != excluding
                && ToolPolicy.projectBlock(tool: toolName, capability: capability, settings: settings(of: $0)) == nil
        }.map(\.name)
        guard !working.isEmpty else { return "\nNo attached project allows this tool right now." }
        return "\nThis tool works in: \(working.joined(separator: ", ")). Pass one of them in the 'project' argument."
    }

    private func finish(_ decision: ToolDecision, argsData: Data, args: [String: String]) -> ToolAuthorization {
        switch decision {
        case .allowed:
            return .allowed(argsData: argsData, args: args)
        case .denied(let message):
            return .denied(message)
        }
    }

    private func resolveTarget(
        toolName: String,
        args: [String: String],
        projects: [ActiveMemoryContext.ProjectInfo]
    ) -> Result<ActiveMemoryContext.ProjectInfo, ResolutionError> {
        if projects.isEmpty { return .failure(ResolutionError("❌ Tool '\(toolName)' needs a project, but none is attached.")) }
        let names = projects.map { "'\($0.name)'" }.joined(separator: ", ")

        guard let requested = args["project"]?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty else {
            return .failure(ResolutionError("""
            ❌ Tool '\(toolName)': the 'project' argument is required, even when only one project is attached. \
            Pass one of: \(names).
            """))
        }

        if let exact = projects.first(where: { $0.name == requested }) { return .success(exact) }
        let folded = projects.filter { $0.name.lowercased() == requested.lowercased() }
        if folded.count == 1 { return .success(folded[0]) }
        return .failure(ResolutionError("❌ Project '\(requested)' is not attached to this thread. Attached: \(names)."))
    }

    private struct ResolutionError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
