// ToolPolicy+Rules.swift
// ChappieCore
//
// The rules themselves. Each returns a ToolBlock (nil = allowed); wording of reasons and fixes lives
// here and nowhere else, so refusals at call time and statuses in tool descriptions always agree.
//
// Evaluation is split in two layers because the descriptions need them separately:
//   threadBlock  — settings of the THREAD (terminal switch, Curl-Chappie switch)
//   projectBlock — settings of ONE project (role, programming flag, git level, build, tests)

import Foundation

extension ToolPolicy {

    // MARK: Full evaluation

    /// nil = the tool may run for this call.
    public static func evaluate(
        tool: String,
        project: ProjectSettings?,
        terminalAccess: TerminalAccessLevel,
        curlEnabled: Bool
    ) -> ToolBlock? {
        guard let capability = capability(of: tool) else {
            return ToolBlock(
                reason: "unknown tool, it is not registered in the tool policy",
                fix: nil, permanent: true
            )
        }
        if let thread = threadBlock(capability, terminalAccess: terminalAccess, curlEnabled: curlEnabled) {
            return thread
        }
        guard capability.needsProject else { return nil }
        guard let project else {
            return ToolBlock(
                reason: "it needs a project, but none could be selected for this call",
                fix: "attach a project to the thread and pass its name in the 'project' argument"
            )
        }
        return projectBlock(tool: tool, capability: capability, settings: project)
    }

    // MARK: Thread layer

    /// Blocks that come from thread settings (and permanent bans); nil when the thread allows the tool.
    public static func threadBlock(
        _ capability: ToolCapability,
        terminalAccess: TerminalAccessLevel,
        curlEnabled: Bool
    ) -> ToolBlock? {
        switch capability {
        case .forbidden:
            return ToolBlock(
                reason: "git_diff is permanently FORBIDDEN: it loads the entire project into the context and costs real money. No setting overrides this",
                fix: "git_status to list changed files, then read_file for the ones you need",
                permanent: true
            )
        case .terminal:
            return terminalAccess.isEnabled ? nil : ToolBlock(
                reason: "terminal access is off for this thread",
                fix: "thread settings → Terminal → 'With confirmation' or 'Automatically'"
            )
        case .curl:
            return curlEnabled ? nil : ToolBlock(
                reason: "Curl-Chappie is off for this thread",
                fix: "thread settings → Curl-Chappie → enable it and add the hosts it may talk to"
            )
        default:
            return nil
        }
    }

    // MARK: Project layer

    /// Blocks that come from ONE project's settings; nil when that project allows the tool.
    public static func projectBlock(
        tool: String,
        capability: ToolCapability,
        settings s: ProjectSettings
    ) -> ToolBlock? {
        switch capability {
        case .fileRead:
            return nil
        case .fileWrite, .curl:
            return executorBlock(s)
        case .locRead:
            return xcodeBlock(s)
        case .locWrite:
            return executorBlock(s) ?? xcodeBlock(s)
        case .git:
            if let block = executorBlock(s) ?? programmingBlock(s) { return block }
            guard s.gitAccess.allowedTools.contains(tool) else {
                let allowed = s.gitAccess.allowedTools.sorted().joined(separator: ", ")
                return ToolBlock(
                    reason: "git access level '\(s.gitAccess.rawValue)' does not include it (allowed at this level: \(allowed.isEmpty ? "none" : allowed))",
                    fix: "project settings → Git → raise the access level"
                )
            }
            return nil
        case .build, .tests, .buildLog:
            return buildBlock(capability, s)
        case .alwaysOn, .terminal, .forbidden:
            return nil   // thread-level; never reaches the project layer
        }
    }

    private static func buildBlock(_ capability: ToolCapability, _ s: ProjectSettings) -> ToolBlock? {
        if let block = executorBlock(s) ?? programmingBlock(s) { return block }
        guard s.buildEnabled else {
            return ToolBlock(
                reason: "compilation is disabled for this project (the user builds manually). Ask the user to build and run tests, then report the result in chat. Do not bypass this through the terminal",
                fix: "project settings → Tests/Build → enable compilation"
            )
        }
        switch capability {
        case .build:
            guard s.devEnvironment.specificTools.contains("build_project") else {
                return ToolBlock(
                    reason: "no build tool exists for a \(s.devEnvironment.displayName) project",
                    fix: nil, permanent: true
                )
            }
            return nil
        case .tests:
            guard s.testsAccess.canRun else {
                return ToolBlock(
                    reason: s.testsAccess == .readOnly ? "tests access is 'read-only' (logs only, no runs)" : "tests access is off",
                    fix: "project settings → Tests → 'Run' or 'Run + Write'"
                )
            }
            return nil
        default:
            guard s.testsAccess.canReadLog else {
                return ToolBlock(
                    reason: "build log access is off",
                    fix: "project settings → Tests → at least 'Read-only'"
                )
            }
            return nil
        }
    }

    // MARK: Requirements

    private static func executorBlock(_ s: ProjectSettings) -> ToolBlock? {
        s.agentRole == .executor ? nil : ToolBlock(
            reason: "the project's role is ADVISOR (read-only)",
            fix: "project settings → role → EXECUTOR"
        )
    }

    private static func programmingBlock(_ s: ProjectSettings) -> ToolBlock? {
        s.isProgrammingProject ? nil : ToolBlock(
            reason: "the project is not marked as a programming project",
            fix: "project settings → enable 'Programming project'"
        )
    }

    private static func xcodeBlock(_ s: ProjectSettings) -> ToolBlock? {
        (s.isProgrammingProject && s.devEnvironment == .xcode) ? nil : ToolBlock(
            reason: s.isProgrammingProject
                ? "it works only on Xcode projects (this one is \(s.devEnvironment.displayName))"
                : "it works only on Xcode projects (this one is not a programming project)",
            fix: "project settings → enable 'Programming project' and set the environment to Xcode"
        )
    }
}
