// ProjectModels+SystemPrompt.swift
// ChappieCore
//
// Formats ProjectSettings into the system prompt block injected into every AI request.

import Foundation

extension ProjectSettings {

    /// absolutePath is passed separately — it's runtime-only, not stored in ProjectSettings.
    public func formatForSystemPrompt(projectName: String, absolutePath: String? = nil) -> String {
        var lines: [String] = ["## Project Settings: \(projectName)"]

        // Inject absolute path so AI always knows where the project lives on disk.
        // This prevents the AI from losing the working directory after context resets.
        if let path = absolutePath, !path.isEmpty {
            lines.append("- Absolute path: \(path)")
        }

        lines.append("- Role: \(agentRole.rawValue.uppercased())")

        if agentRole == .advisor {
            lines.append("- Access: read-only (list_files, read_file). All write/git/test/terminal tools are BLOCKED.")
            lines.append("- To unlock tools: go to project settings → change role to Executor.")
            return lines.joined(separator: "\n")
        }

        lines.append("- Programming project: \(isProgrammingProject ? "yes" : "no")")

        if isProgrammingProject {
            if devEnvironment != .unknown {
                lines.append("- Dev environment: \(devEnvironment.displayName)")
            }

            if gitAccess == .none {
                lines.append("- Git: BLOCKED (enable in project settings)")
            } else {
                let toolsList = gitAccess.allowedTools.sorted().joined(separator: ", ")
                lines.append("- Git: \(gitAccess.rawValue) [\(toolsList)] [git_diff: ALWAYS FORBIDDEN]")
            }

            if !buildEnabled {
                lines.append("- Compilation: DISABLED for this project (build_project, run_tests, read_build_log are all UNAVAILABLE — too slow to compile here). After making code changes, ASK THE USER to build and run tests themselves in their IDE, then report the results back to you in chat before you proceed or commit. NEVER use run_terminal (e.g. xcodebuild, swift build, swift test) to bypass this restriction — the user disabled compilation on purpose (usually because the project is too large/slow to build repeatedly), and going around it via terminal defeats that intent.")
            } else {
                switch testsAccess {
                case .none:
                    lines.append("- Tests: BLOCKED (enable in project settings)")
                case .readOnly:
                    lines.append("- Tests: read logs only (read_build_log). run_tests is BLOCKED.")
                case .run:
                    lines.append("- Tests: run allowed (build_project, run_tests, read_build_log). Creating new tests: BLOCKED. You are required to run tests after changes when necessary. UI layer tests are low ROI and not required unless explicitly requested.")
                case .write:
                    lines.append("- Tests: run + create allowed (build_project, run_tests, read_build_log, write test files). You are required to write tests for business logic, services, and non-trivial algorithms when necessary. You are required to run tests after changes when necessary. UI layer tests are low ROI and not required unless explicitly requested.")
                }
            }

            if architectureEnabled {
                // Use promptValue so AI gets a clear language name, not a raw code.
                lines.append("- Architecture files: enabled (\(architectureLanguage.promptValue)). Discuss file paths with user before creating. If architecture files are found, save their paths to project memory and use them as a reference during development when relevant. You are required to keep architecture files up to date after code changes that affect the described structure. Keep architecture files concise: describe structure and decisions, not implementation details. Remove sections that are no longer relevant — dead history belongs in git, not in architecture files.")
            } else {
                lines.append("- Architecture files: read-only (enable write in project settings)")
            }

            if commentsEnabled {
                // Use promptValue so AI gets a clear language name, not a raw code.
                lines.append("- Code comments: enabled (\(commentsLanguage.promptValue)). Be concise — explain WHY, not WHAT. Write only when the code is non-obvious. Delete comments that are outdated or describe obvious operations. Never let comments outnumber or outsize the code they describe.")
            } else {
                lines.append("- Code comments: DISABLED (enable in project settings)")
            }

            switch terminalAccess {
            case .none:
                break // terminal not mentioned — thread-level setting takes precedence if set
            case .confirm:
                lines.append("- Terminal: enabled with confirmation. BEFORE running any command you MUST ask the user for explicit approval in chat. Do NOT call run_terminal until user says 'yes', 'go ahead', or equivalent.")
            case .auto:
                lines.append("- Terminal: enabled, auto-execute (no confirmation needed). Use responsibly.")
            }
        } else {
            lines.append("- Advanced settings (git, tests, architecture, comments, terminal): locked. Enable 'Programming project' in settings.")
        }

        return lines.joined(separator: "\n")
    }
}
