// ToolPolicy.swift
// ChappieCore
//
// THE single source of truth for "may this tool run?". Pure and synchronous: no actors, no I/O.
//
// Every tool the model can call has exactly one row in `table`. A tool without a row is DENIED
// (deny by default) — a new tool that nobody classified simply does not work, instead of silently
// shipping unprotected. A completeness test walks all tool definitions and fails on a missing row.
//
// The rules live in ToolPolicy+Rules.swift and answer with a structured `ToolBlock` (reason + fix),
// never with ready-made prose. Two consumers build their text from the SAME block, so they cannot drift:
//   - call time   (ToolExecutionService.authorize)  → `decide` → "❌ Tool 'x' is blocked: …"
//   - description (tool list shown to the model)    → ToolStatus → "[UNAVAILABLE in: …]"
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

// MARK: - Block

/// Why a tool cannot run, and what (if anything) the user can change to make it run.
public struct ToolBlock: Sendable, Equatable {
    /// What is wrong, as a short phrase without a trailing period.
    public let reason: String
    /// Where the user fixes it ("project settings → role → EXECUTOR"). For a permanent block:
    /// the alternative the model should use instead.
    public let fix: String?
    /// True when no setting can ever enable the tool (git_diff, unknown tools).
    public let permanent: Bool

    public init(reason: String, fix: String?, permanent: Bool = false) {
        self.reason = reason
        self.fix = fix
        self.permanent = permanent
    }

    /// "reason. To enable: fix" — the shared wording used inside tool descriptions.
    public var summary: String {
        guard let fix else { return reason }
        return permanent ? "\(reason). Instead: \(fix)" : "\(reason). To enable: \(fix)"
    }

    /// Refusal text returned to the model when it calls the tool anyway.
    public func message(tool: String) -> String {
        permanent ? "❌ Tool '\(tool)' cannot be used: \(summary)"
                  : "❌ Tool '\(tool)' is blocked: \(summary)"
    }
}

// MARK: - Capability

/// What a tool needs in order to run. One capability per tool.
public enum ToolCapability: Sendable {
    /// Memory, web, attachments, project list: no project needed.
    case alwaysOn
    /// run_terminal / run_ssh: thread-level switch, no project.
    case terminal
    /// computer_screenshot / computer_click / computer_scroll / computer_type: thread-level switch, no project.
    case computerUse
    /// Never allowed, whatever the settings (git_diff).
    case forbidden
    /// Read files and documents of a project (ADVISOR and EXECUTOR).
    case fileRead
    /// Create, change, move or delete files (EXECUTOR only).
    case fileWrite
    /// git_*: EXECUTOR on a programming project, limited by the project's git level.
    case git
    /// curl_request / curl_session / curl_extract: thread switch AND an EXECUTOR project
    /// (the project supplies the secrets). ADVISOR never gets them.
    case curl

    /// True when the call targets one concrete project and that project's rights apply.
    public var needsProject: Bool {
        switch self {
        case .alwaysOn, .terminal, .computerUse, .forbidden: return false
        default: return true
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
        add(.computerUse, [
            "computer_screenshot", "computer_move_to", "computer_move_by", "computer_click", "computer_scroll", "computer_type"
        ])
        add(.forbidden, ["git_diff"])
        add(.fileRead, [
            "list_files", "read_file", "get_file_info", "view_image",
            "read_document", "search_in_file", "search_in_project",
            "json_info", "json_schema", "json_get", "json_find"
        ])
        add(.fileWrite, [
            "write_file", "patch_file", "delete_file", "move_file", "rename_file",
            "write_document", "json_edit"
        ])
        add(.git, [
            "git_status", "git_log", "git_add", "git_commit", "git_push",
            "git_reset", "git_revert", "git_checkout"
        ])
        add(.curl, [
            "curl_request", "curl_session", "curl_extract",
            "curl_scenario_info", "curl_scenario_save", "curl_scenario_delete", "curl_scenario_run"
        ])
        return rows
    }()

    /// Capability of a tool, or nil when the tool is not classified (= denied).
    public static func capability(of tool: String) -> ToolCapability? { table[tool] }

    /// Every classified tool name.
    public static var knownTools: Set<String> { Set(table.keys) }

    // MARK: Decision

    /// - Parameters:
    ///   - project: settings of the project the call targets; nil when the tool needs none
    ///     (or when the target could not be resolved — project tools are then denied).
    ///   - terminalEnabled: thread-level terminal switch.
    ///   - curlEnabled: thread-level Curl-Chappie switch.
    public static func decide(
        tool: String,
        project: ProjectSettings?,
        terminalEnabled: Bool,
        curlEnabled: Bool = false,
        computerUseEnabled: Bool = false
    ) -> ToolDecision {
        guard let block = evaluate(
            tool: tool, project: project, terminalEnabled: terminalEnabled, curlEnabled: curlEnabled, computerUseEnabled: computerUseEnabled
        ) else { return .allowed }
        return .denied(block.message(tool: tool))
    }
}
