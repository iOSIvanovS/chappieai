// ToolPolicy.swift
// ChappieCore
//
// THE single source of truth for "may this tool run?". Pure and synchronous: no actors, no I/O.
//
// Every tool the model can call has exactly one row in `table`. A tool without a row is DENIED
// (deny by default) — a new tool that nobody classified simply does not work, instead of silently
// shipping unprotected. A completeness test walks all tool definitions and fails on a missing row.
//
// The same `decide` answers both questions:
//   - exposure  (which tools the model is shown)      → ToolExecutionService.isToolExposed
//   - execution (which call is actually allowed to run) → ToolExecutionService.authorize
//
// Rights are evaluated against ONE project: the one the call targets. Rights of other attached
// projects never leak into the decision (a read-only project cannot be written to just because a
// sibling project is an EXECUTOR).

import Foundation

// MARK: - Decision

public enum ToolDecision: Sendable, Equatable {
    case allowed
    case denied(String)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

// MARK: - Capability

/// What a tool needs in order to run. One capability per tool.
public enum ToolCapability: Sendable {
    /// Memory, web, attachments, project list: no project, every plan.
    case alwaysOn
    /// run_terminal / run_ssh: thread-level switch, no project.
    case terminal
    /// Never allowed, whatever the settings (git_diff).
    case forbidden
    /// Read files and documents of a project (ADVISOR and EXECUTOR).
    case fileRead
    /// Create, change, move or delete files (EXECUTOR only).
    case fileWrite
    /// Read-only localization tools; needs an Xcode project.
    case locRead
    /// Localization tools that change files; EXECUTOR on an Xcode project.
    case locWrite
    /// git_*: EXECUTOR on a programming project, limited by the project's git level.
    case git
    /// build_project.
    case build
    /// run_tests.
    case tests
    /// read_build_log.
    case buildLog
    /// curl_request / curl_session / curl_extract: thread switch AND an EXECUTOR project
    /// (the project supplies the secrets). ADVISOR never gets them.
    case curl

    /// True when the call targets one concrete project and that project's rights apply.
    public var needsProject: Bool {
        switch self {
        case .alwaysOn, .terminal, .forbidden: return false
        default: return true
        }
    }

    /// Starter plan is read-only: it may use these and nothing else.
    var allowedOnStarter: Bool {
        switch self {
        case .alwaysOn, .fileRead, .locRead: return true
        default: return false
        }
    }
}

// MARK: - Policy

public enum ToolPolicy {

    // MARK: Table

    private static let table: [String: ToolCapability] = {
        var rows: [String: ToolCapability] = [:]
        func add(_ capability: ToolCapability, _ names: [String]) {
            for name in names { rows[name] = capability }
        }

        add(.alwaysOn, [
            "web_fetch",
            "memorize", "recall", "search_memory", "delete_memory",
            "list_thread_projects",
            "fetch_attachment", "send_attachment",
            // A PDF may be an attachment in a thread without any project; a project path is resolved
            // by PDFTools itself and the helper's PathGuard keeps it inside that project.
            "pdf_info", "pdf_page_as_txt", "pdf_page_as_image"
        ])
        add(.terminal, ["run_terminal", "run_ssh"])
        add(.forbidden, ["git_diff"])
        add(.fileRead, [
            "list_files", "read_file", "get_file_info", "view_image",
            "read_document", "search_in_file", "search_in_project"
        ])
        add(.fileWrite, [
            "write_file", "patch_file", "delete_file", "move_file", "rename_file",
            "write_document"
        ])
        // loc_next_batch only keeps its cursor in /tmp and never touches project files — a read.
        add(.locRead, ["loc_info", "loc_key_check", "loc_list_keys", "loc_next_batch", "loc_dead_keys"])
        add(.locWrite, [
            "loc_create", "loc_rename", "loc_delete",
            "loc_add_language", "loc_remove_language", "loc_submit_batch",
            "loc_add_key", "loc_remove_key", "loc_rename_key", "loc_rename_keys"
        ])
        add(.git, [
            "git_status", "git_log", "git_add", "git_commit", "git_push",
            "git_reset", "git_revert", "git_checkout"
        ])
        add(.build, ["build_project"])
        add(.tests, ["run_tests"])
        add(.buildLog, ["read_build_log"])
        add(.curl, [
            "curl_request", "curl_session", "curl_extract",
            "curl_scenario_info", "curl_scenario_save", "curl_scenario_delete"
        ])
        return rows
    }()

    /// Capability of a tool, or nil when the tool is not classified (= denied).
    public static func capability(of tool: String) -> ToolCapability? { table[tool] }

    /// Every classified tool name.
    public static var knownTools: Set<String> { Set(table.keys) }

    /// All tools that route to ChappieMCP's localization module.
    public static var localizationTools: Set<String> {
        Set(table.filter { $0.value == .locRead || $0.value == .locWrite }.keys)
    }

    // MARK: Decision

    /// - Parameters:
    ///   - project: settings of the project the call targets; nil when the tool needs none
    ///     (or when the target could not be resolved — project tools are then denied).
    ///   - terminalAccess: thread-level terminal switch.
    ///   - isStarterPlan: Starter is read-only.
    ///   - curlEnabled: thread-level Curl-Chappie switch.
    public static func decide(
        tool: String,
        project: ProjectSettings?,
        terminalAccess: TerminalAccessLevel,
        isStarterPlan: Bool,
        curlEnabled: Bool = false
    ) -> ToolDecision {
        guard let capability = table[tool] else {
            return .denied("❌ Unknown tool '\(tool)'. It is not registered in the tool policy, so it cannot be used.")
        }

        if capability == .forbidden {
            return .denied("""
            ❌ git_diff is permanently FORBIDDEN — it loads the entire project into AI context and costs real money.
            This prohibition cannot be overridden by any settings.
            Use git_status to see changed files, then read_file for specific files if needed.
            """)
        }

        if capability == .alwaysOn { return .allowed }

        if isStarterPlan && !capability.allowedOnStarter {
            return .denied("""
            ❌ Tool '\(tool)' requires a Pro or Team license.
            Your current plan (Starter) provides read-only access only.
            Upgrade to Pro or Team to unlock full execution capabilities.
            """)
        }

        if capability == .curl && !curlEnabled {
            return .denied("""
            ❌ Tool '\(tool)' is blocked: Curl-Chappie is switched off for this thread.
            Open thread settings → Curl-Chappie → enable it and add the hosts it may talk to.
            """)
        }

        if capability == .terminal {
            return terminalAccess.isEnabled ? .allowed : .denied("""
            ❌ Tool '\(tool)' is blocked: terminal access is disabled for this thread.
            Open thread settings → Terminal → choose 'With confirmation' or 'Automatically'.
            """)
        }

        guard let settings = project else {
            return .denied("❌ Tool '\(tool)' needs a project, but none could be selected for this call.")
        }
        return decideForProject(tool: tool, capability: capability, settings: settings)
    }

    // MARK: Per-project rules

    private static func decideForProject(
        tool: String,
        capability: ToolCapability,
        settings s: ProjectSettings
    ) -> ToolDecision {
        switch capability {
        case .fileRead:
            return .allowed

        case .fileWrite:
            return requireExecutor(tool, s)

        case .locRead:
            return requireXcode(tool, s)

        case .locWrite:
            if case .denied(let why) = requireExecutor(tool, s) { return .denied(why) }
            return requireXcode(tool, s)

        case .git:
            if case .denied(let why) = requireExecutor(tool, s) { return .denied(why) }
            if case .denied(let why) = requireProgramming(tool, s) { return .denied(why) }
            guard s.gitAccess.allowedTools.contains(tool) else {
                return .denied("""
                ❌ Tool '\(tool)' is blocked by git access level '\(s.gitAccess.rawValue)'.
                Open project settings → Git → increase access level.
                Allowed tools at current level: \(s.gitAccess.allowedTools.sorted().joined(separator: ", "))
                """)
            }
            return .allowed

        case .build, .tests, .buildLog:
            return decideBuild(tool: tool, capability: capability, settings: s)

        case .curl:
            return requireExecutor(tool, s)

        case .alwaysOn, .terminal, .forbidden:
            return .denied("❌ Tool '\(tool)' is not available.")   // handled before; unreachable
        }
    }

    private static func decideBuild(
        tool: String,
        capability: ToolCapability,
        settings s: ProjectSettings
    ) -> ToolDecision {
        if case .denied(let why) = requireExecutor(tool, s) { return .denied(why) }
        if case .denied(let why) = requireProgramming(tool, s) { return .denied(why) }

        guard s.buildEnabled else {
            return .denied("""
            ❌ Tool '\(tool)' is disabled for this project (compilation is too slow — user builds manually).
            Ask the user to build and run tests themselves, then report the results back to you in chat.
            """)
        }

        switch capability {
        case .build:
            guard s.devEnvironment.specificTools.contains("build_project") else {
                return .denied("❌ Tool 'build_project' does not apply to a \(s.devEnvironment.displayName) project.")
            }
            return .allowed
        case .tests:
            guard s.testsAccess.canRun else {
                if s.testsAccess == .readOnly {
                    return .denied("""
                    ❌ Tool 'run_tests' is blocked: tests access is 'read-only'.
                    You can read logs via read_build_log, but cannot run tests.
                    Open project settings → Tests → set to 'Run' or 'Run + Write'.
                    """)
                }
                return .denied("""
                ❌ Tool 'run_tests' is blocked: tests access is disabled.
                Open project settings → Tests → enable test access.
                """)
            }
            return .allowed
        default:
            guard s.testsAccess.canReadLog else {
                return .denied("""
                ❌ Tool 'read_build_log' is blocked: log access is disabled.
                Open project settings → Tests → enable at least log reading.
                """)
            }
            return .allowed
        }
    }

    // MARK: Requirements

    private static func requireExecutor(_ tool: String, _ s: ProjectSettings) -> ToolDecision {
        s.agentRole == .executor ? .allowed : .denied("""
        ❌ Tool '\(tool)' is blocked: current role is ADVISOR (read-only).
        To enable this tool: open project settings → change role to EXECUTOR.
        """)
    }

    private static func requireProgramming(_ tool: String, _ s: ProjectSettings) -> ToolDecision {
        s.isProgrammingProject ? .allowed : .denied("""
        ❌ Tool '\(tool)' requires 'Programming project' flag.
        Open project settings → enable 'Programming project'.
        """)
    }

    private static func requireXcode(_ tool: String, _ s: ProjectSettings) -> ToolDecision {
        (s.isProgrammingProject && s.devEnvironment == .xcode) ? .allowed : .denied("""
        ❌ Tool '\(tool)' works only on an Xcode project.
        Open project settings → enable 'Programming project' and set the environment to Xcode.
        """)
    }
}
