// New+ToolAccessController.swift
// ChappieCore / V2
//
// Hard gate before every tool call in the V2 thread isolation architecture.
// Replaces the ad-hoc checkToolAccess() in ToolExecutionService (M-04).
//
// KEY DIFFERENCE from old ToolAccessControl.swift:
//   Old: reads activeProjectSettings (first project only — MVP simplification).
//   New: accepts pre-merged ToolPermissions built by SystemPromptBuilder.toolPermissions()
//        from ALL projects in the thread — most permissive wins across projects.
//
// CONTRACT:
//   - Pure static function: no async, no SwiftData, no side effects.
//   - Returns structured AccessResult, not a raw string.
//   - Caller (ToolExecutionService V2 path) converts .denied to JSON error response.
//   - git_diff IRON PROHIBITION is enforced here — cannot be overridden by any settings.

import Foundation

extension New {

    // MARK: - Access result

    public enum AccessResult: Sendable {
        case allowed
        case denied(reason: String)

        public var isAllowed: Bool {
            if case .allowed = self { return true }
            return false
        }

        /// Formats the denial as a JSON error string for the AI to read.
        public func denialJSON(toolName: String) -> String {
            guard case .denied(let reason) = self else { return "{}" }
            let escaped = reason
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return """
            {"error":"tool_access_denied","tool":"\(toolName)","reason":"\(escaped)"}
            """
        }
    }

    // MARK: - Controller

    public struct ToolAccessController {

        // Tools that require at least read-file access.
        private static let readTools: Set<String> = ["list_files", "read_file"]

        // Tools that require write-file access.
        private static let writeTools: Set<String> = [
            "write_file", "delete_file"
        ]

        // Tools that require build/test access.
        private static let buildTools: Set<String> = ["build_project", "run_tests"]

        // Git tools grouped by required level.
        private static let gitStatusTools: Set<String> = ["git_status"]
        private static let gitWriteTools: Set<String> = ["git_add", "git_commit", "git_reset"]
        private static let gitFullTools: Set<String> = [
            "git_log", "git_revert", "git_checkout"
        ]

        // Always allowed — memory, web, thread management.
        private static let alwaysAllowed: Set<String> = [
            "web_fetch",
            "memorize", "recall", "search_memory", "delete_memory",
            "add_project_to_thread", "remove_project_from_thread", "list_thread_projects"
        ]

        /// Checks whether a tool may be executed given the merged thread permissions.
        ///
        /// - Parameters:
        ///   - toolName: Exact tool name as sent by the AI model.
        ///   - permissions: Pre-merged ToolPermissions from SystemPromptBuilder.toolPermissions().
        /// - Returns: .allowed or .denied(reason:).
        public static func check(
            toolName: String,
            permissions: ToolPermissions
        ) -> AccessResult {

            // IRON PROHIBITION: git_diff is always blocked — no override possible.
            if toolName == "git_diff" {
                return .denied(reason: """
                git_diff is permanently FORBIDDEN — it loads the entire project into AI context \
                and costs real money. This prohibition cannot be overridden by any settings. \
                Use git_status to see changed files, then read_file for specific files if needed.
                """)
            }

            // Always-on tools: memory, web, thread management.
            if alwaysAllowed.contains(toolName) {
                return .allowed
            }

            // Read-file tools.
            if readTools.contains(toolName) {
                return permissions.canReadFiles
                    ? .allowed
                    : .denied(reason: "Tool '\(toolName)' requires read access. Open project settings → set role to ADVISOR or EXECUTOR.")
            }

            // Write-file tools.
            if writeTools.contains(toolName) {
                return permissions.canWriteFiles
                    ? .allowed
                    : .denied(reason: "Tool '\(toolName)' requires write access. Open project settings → set role to EXECUTOR.")
            }

            // Build/test tools.
            if buildTools.contains(toolName) {
                guard permissions.canRunTests else {
                    return .denied(reason: "Tool '\(toolName)' requires test execution access. Open project settings → Tests → set to 'Run' or 'Run + Write'.")
                }
                return .allowed
            }

            // read_build_log — available if canReadBuildLog is true.
            if toolName == "read_build_log" {
                return permissions.canReadBuildLog
                    ? .allowed
                    : .denied(reason: "Tool 'read_build_log' requires at least 'Read logs' test access. Open project settings → Tests → enable.")
            }

            // Git tools — checked by level.
            if gitStatusTools.contains(toolName) {
                guard permissions.gitLevel != .none else {
                    return .denied(reason: "Tool '\(toolName)' requires git access. Open project settings → Git → enable.")
                }
                return .allowed
            }

            if gitWriteTools.contains(toolName) {
                let rank = gitLevelRank(permissions.gitLevel)
                guard rank >= gitLevelRank(.write) else {
                    return .denied(reason: "Tool '\(toolName)' requires git write access. Open project settings → Git → set to 'Write' or 'Full'.")
                }
                return .allowed
            }

            if gitFullTools.contains(toolName) {
                guard permissions.gitLevel == .full else {
                    return .denied(reason: "Tool '\(toolName)' requires full git access. Open project settings → Git → set to 'Full'.")
                }
                return .allowed
            }

            // Unknown tool — allow by default (forward-compatible: new tools don't break).
            return .allowed
        }

        // MARK: - Private helpers

        private static func gitLevelRank(_ level: GitAccessLevel) -> Int {
            switch level {
            case .none:       return 0
            case .statusOnly: return 1
            case .write:      return 2
            case .full:       return 3
            }
        }
    }
}
