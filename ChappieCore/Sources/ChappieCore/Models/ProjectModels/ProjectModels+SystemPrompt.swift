// ProjectModels+SystemPrompt.swift
// ChappieCore
//
// Formats ProjectSettings into the system prompt block injected into every AI request.
//
// Only facts that no tool status carries live here: path, the test-writing
// permission, and the architecture/comment switches with their language. Role and git level
// are stated by the tool statuses (ToolPolicy.status).

import Foundation

extension ProjectSettings {

    /// absolutePath is passed separately — it's runtime-only, not stored in ProjectSettings.
    public func formatForSystemPrompt(projectName: String, absolutePath: String? = nil) -> String {
        var lines: [String] = ["## Project Settings: \(projectName)"]

        if let path = absolutePath, !path.isEmpty {
            lines.append("- Absolute path: \(path)")
        }

        // Advisor and non-programming projects have nothing beyond the path to report.
        guard agentRole == .executor, isProgrammingProject else {
            return lines.joined(separator: "\n")
        }

        // Writing tests goes through the shared write tools, so no tool status can express this.
        lines.append(testsWriteEnabled
                     ? "- Tests: creating tests allowed"
                     : "- Tests: creating new tests not allowed")

        lines.append(architectureEnabled
                     ? "- Architecture files: enabled (\(architectureLanguage.promptValue))"
                     : "- Architecture files: read-only (enable write in project settings)")

        lines.append(commentsEnabled
                     ? "- Code comments: enabled (\(commentsLanguage.promptValue))"
                     : "- Code comments: disabled (enable in project settings)")

        return lines.joined(separator: "\n")
    }
}
