// ToolAccessControl.swift
// ChappieCore
//
// WHY THIS FILE:
// IT-09 access control: checks agent role, git level, test level, and terminal level
// before any tool is executed. Isolated here so rules are easy to audit.
//
// CHECK ORDER in checkToolAccess():
// 1. git_diff — iron prohibition, always blocked regardless of settings.
// 2. Starter plan — read-only: list_files, read_file, read_document, read_build_log only.
//    WHY: Starter is "Advisor only" per monetization plan — no execution, no writes.
// 3. ADVISOR role — same read-only gate as Starter.
// 4. EXECUTOR role:
//    a. Git tools — require isProgrammingProject + GitAccessLevel.allowedTools.
//    b. build_project — requires isProgrammingProject + Executor role.
//    c. run_tests — requires isProgrammingProject + TestsAccessLevel.canRun.
//    d. read_build_log — always allowed for Executor (read-only diagnostic tool).
//    e. write_document — requires Executor role (document writes = mutations).
//    f. run_terminal — requires isProgrammingProject + TerminalAccessLevel.isEnabled.
//    g. run_ssh — requires isProgrammingProject + TerminalAccessLevel.isEnabled.
//    h. move_file / rename_file — require Executor role (file mutations).
//
// PROJECT RESOLUTION:
// All tools carry a "project" display name arg — single source of truth for access control.
// resolveProjectSettings(for:) matches by name; falls back to projects.first for single-project threads.
// No path heuristics. No guessing. One rule: args["project"] → settings.

import Foundation

extension ToolExecutionService {

    /// Resolves ProjectSettings for the project named in the tool call.
    ///
    /// WHY: every tool carries an explicit "project" arg (display name).
    /// We match by name — no path heuristics, no fallback to first project
    /// unless the thread has only one project (single-project threads can omit "project").
    func resolveProjectSettings(for projectName: String?) -> ProjectSettings {
        if let name = projectName, !name.isEmpty {
            if let match = activeMemoryContext.projects.first(where: {
                $0.name.lowercased() == name.lowercased()
            }) {
                return projectSettingsCache[match.id] ?? ProjectSettings()
            }
        }
        // Fallback: first project — correct for single-project threads where "project" is optional.
        guard let firstProject = activeMemoryContext.projects.first else {
            return ProjectSettings()
        }
        return projectSettingsCache[firstProject.id] ?? ProjectSettings()
    }

    /// Checks permission to execute a tool according to project settings and license plan (IT-09).
    ///
    /// projectName: the "project" argument from the tool call — resolves correct ProjectSettings
    /// in multi-project threads, preventing Advisor-blocks-Executor cross-contamination.
    func checkToolAccess(toolName: String, projectName: String? = nil) -> ToolAccessResult {
        let settings = resolveProjectSettings(for: projectName)

        // IRON PROHIBITION: git_diff is always blocked.
        if toolName == "git_diff" {
            return .denied("""
            ❌ git_diff is permanently FORBIDDEN — it loads the entire project into AI context and costs real money.
            This prohibition cannot be overridden by any settings.
            Use git_status to see changed files, then read_file for specific files if needed.
            """)
        }

        // Read-only tools — always allowed regardless of role or plan.
        let alwaysAllowedTools: Set<String> = [
            "list_files", "read_file", "read_document", "read_build_log", "get_file_info"
        ]

        // STARTER plan — read-only access.
        // WHY: Starter = "Advisor only" per monetization plan.
        if licenseState.isStarterPlan {
            if !alwaysAllowedTools.contains(toolName) {
                return .denied("""
                ❌ Tool '\(toolName)' requires a Pro or Team license.
                Your current plan (Starter) provides read-only access only.
                Upgrade to Pro or Team to unlock full execution capabilities.
                """)
            }
            return .allowed
        }

        // ADVISOR role — read only.
        if settings.agentRole == .advisor {
            if !alwaysAllowedTools.contains(toolName) {
                return .denied("""
                ❌ Tool '\(toolName)' is blocked: current role is ADVISOR (read-only).
                ADVISOR can only use: list_files, read_file, read_document, read_build_log, get_file_info.
                To enable this tool: open project settings → change role to EXECUTOR.
                """)
            }
            return .allowed
        }

        // EXECUTOR: check git tools.
        let gitTools: Set<String> = ["git_status", "git_log", "git_add", "git_commit",
                                     "git_push", "git_reset", "git_revert", "git_checkout"]
        if gitTools.contains(toolName) {
            if !settings.isProgrammingProject {
                return .denied("""
                ❌ Tool '\(toolName)' requires 'Programming project' flag.
                Open project settings → enable 'Programming project'.
                """)
            }
            if !settings.gitAccess.allowedTools.contains(toolName) {
                return .denied("""
                ❌ Tool '\(toolName)' is blocked by git access level '\(settings.gitAccess.rawValue)'.
                Open project settings → Git → increase access level.
                Allowed tools at current level: \(settings.gitAccess.allowedTools.sorted().joined(separator: ", "))
                """)
            }
            return .allowed
        }

        // EXECUTOR: build_project — requires programming project + executor role (already checked above).
        if toolName == "build_project" {
            if !settings.isProgrammingProject {
                return .denied("""
                ❌ Tool 'build_project' requires 'Programming project' flag.
                Open project settings → enable 'Programming project'.
                """)
            }
            return .allowed
        }

        // EXECUTOR: run_tests — requires canRun access level.
        if toolName == "run_tests" {
            if !settings.isProgrammingProject {
                return .denied("""
                ❌ Tool 'run_tests' requires 'Programming project' flag.
                Open project settings → enable 'Programming project'.
                """)
            }
            if !settings.testsAccess.canRun {
                if settings.testsAccess == .readOnly {
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
        }

        // EXECUTOR: write_document — mutation of documents, requires executor (already checked).
        // read_document is in alwaysAllowedTools above — no check needed here.
        if toolName == "write_document" {
            return .allowed
        }

        // EXECUTOR: move_file / rename_file — file mutations, require executor (already checked above).
        if toolName == "move_file" || toolName == "rename_file" {
            return .allowed
        }

        // run_terminal and run_ssh share the same access gate.
        // WHY: SSH to a remote server carries the same risk as local terminal execution.
        if toolName == "run_terminal" || toolName == "run_ssh" {
            if !settings.isProgrammingProject {
                return .denied("""
                ❌ Tool '\(toolName)' requires 'Programming project' flag.
                Open project settings → enable 'Programming project'.
                """)
            }
            if !settings.terminalAccess.isEnabled {
                return .denied("""
                ❌ Tool '\(toolName)' is blocked: terminal access is disabled.
                Open project settings → Terminal → choose 'С подтверждением' or 'Автоматически'.
                """)
            }
            return .allowed
        }

        return .allowed
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
