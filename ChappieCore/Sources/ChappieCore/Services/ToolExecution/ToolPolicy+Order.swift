// ToolPolicy+Order.swift
// ChappieCore
//
// Two pieces of presentation knowledge about tools, kept next to the policy table:
//   - dangerOrder: the order the model sees tools in, from the most harmless to the most dangerous.
//     Models tend to reach for tools listed first, so a safe tool wins over a risky one that can do
//     the same job (write_file before "echo > file" through the terminal).
//   - groupTitle: tools that are switched on and off by the same setting share one title; when they are
//     all closed the model gets one group description instead of a full definition per tool.
//
// A completeness test fails when a classified tool is missing from dangerOrder.

import Foundation

extension ToolPolicy {

    /// Harmless → dangerous. Within a family the order follows the damage a mistake can do.
    /// run_terminal and run_ssh are listed first so they survive provider-side tool-list truncation
    /// (RouterAI was observed dropping tools beyond position ~22).
    public static let dangerOrder: [String] = [
        // Computer Use — first to survive provider tool-list truncation alongside terminal
        "computer_screenshot", "computer_move_to", "computer_move_by", "computer_click", "computer_scroll", "computer_type",
        // Arbitrary commands — promoted to front to survive provider tool-list truncation
        "run_terminal", "run_ssh",
        // Orientation and memory
        "list_thread_projects", "recall", "search_memory", "memorize", "delete_memory",
        // Attachments, documents and the web (read-only)
        "fetch_attachment", "pdf_info", "pdf_page_as_txt", "pdf_page_as_image", "web_fetch",
        // Reading project files
        "list_files", "get_file_info", "json_info", "json_schema", "json_get", "json_find",
        "read_file", "view_image", "search_in_file", "search_in_project", "read_document",
        // Changing project files
        "send_attachment", "write_file", "patch_file", "json_edit", "write_document", "rename_file", "move_file", "delete_file",
        // Git
        "git_status", "git_log", "git_add", "git_commit", "git_reset", "git_push", "git_checkout", "git_revert",
        // Network requests
        "curl_scenario_info", "curl_extract", "curl_session", "curl_request",
        "curl_scenario_save", "curl_scenario_delete", "curl_scenario_run",
        // Never allowed
        "git_diff"
    ]

    private static let rankTable: [String: Int] = {
        var table: [String: Int] = [:]
        for (index, name) in dangerOrder.enumerated() { table[name] = index }
        return table
    }()

    /// Position in `dangerOrder`; an unlisted tool sorts last.
    public static func dangerRank(of tool: String) -> Int { rankTable[tool] ?? dangerOrder.count }

    /// Title of the group a tool belongs to; tools of one group are switched by the same settings.
    public static func groupTitle(of tool: String) -> String {
        guard let capability = capability(of: tool) else { return tool }
        switch capability {
        case .alwaysOn:     return "General tools"
        case .terminal:     return "Terminal and SSH"
        case .computerUse:  return "Computer Use"
        case .forbidden:    return tool
        case .fileRead:     return "Project file reading"
        case .fileWrite:    return "Project file changes"
        case .git:          return "Git"
        case .curl:         return "Curl-Chappie (HTTP requests and scenarios)"
        }
    }
}
