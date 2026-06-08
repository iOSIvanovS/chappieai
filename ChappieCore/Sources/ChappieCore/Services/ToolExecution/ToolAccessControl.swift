// ToolAccessControl.swift
// ChappieCore
//
// WHY THIS FILE:
// IT-09 access control: checks agent role, git level, test level, and terminal level
// before any tool is executed. Isolated here so rules are easy to audit.
//
// CHECK ORDER in checkToolAccess():
// 1. git_diff — iron prohibition, always blocked regardless of settings.
// 2. Starter plan — read-only: list_files, read_file, read_document only.
//    WHY: Starter is "Advisor only" per monetization plan — no execution, no writes.
// 3. ADVISOR role — same read-only gate as Starter.
// 4. EXECUTOR role:
//    a. Git tools — require isProgrammingProject + GitAccessLevel.allowedTools.
//    b. Build/test tools — require isProgrammingProject + TestsAccessLevel.canRun.
//    c. read_build_log — requires TestsAccessLevel.canReadLog.
//    d. run_terminal — requires isProgrammingProject + TerminalAccessLevel.isEnabled.
//    e. run_ssh — requires isProgrammingProject + TerminalAccessLevel.isEnabled.

import Foundation

extension ToolExecutionService {

    /// Settings of the first project in the active thread.
    var activeProjectSettings: ProjectSettings {
        guard let firstProject = activeMemoryContext.projects.first else {
            return ProjectSettings()
        }
        return projectSettingsCache[firstProject.id] ?? ProjectSettings()
    }

    /// Checks permission to execute a tool according to project settings and license plan (IT-09).
    func checkToolAccess(toolName: String) -> ToolAccessResult {
        let settings = activeProjectSettings

        // IRON PROHIBITION: git_diff is always blocked.
        if toolName == "git_diff" {
            return .denied("""
            ❌ git_diff is permanently FORBIDDEN — it loads the entire project into AI context and costs real money.
            This prohibition cannot be overridden by any settings.
            Use git_status to see changed files, then read_file for specific files if needed.
            """)
        }

        // STARTER plan — read-only access (same as ADVISOR).
        // WHY: Starter = "Advisor only" per monetization plan.
        if licenseState.isStarterPlan {
            let readOnlyTools: Set<String> = ["list_files", "read_file", "read_document", "read_build_log"]
            if !readOnlyTools.contains(toolName) {
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
            let readOnlyTools: Set<String> = ["list_files", "read_file", "read_build_log"]
            if !readOnlyTools.contains(toolName) {
                return .denied("""
                ❌ Tool '\(toolName)' is blocked: current role is ADVISOR (read-only).
                ADVISOR can only use: list_files, read_file, read_build_log.
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

        // EXECUTOR: check build/test tools.
        let buildTools: Set<String> = ["build_project", "run_tests"]
        if buildTools.contains(toolName) {
            if !settings.isProgrammingProject {
                return .denied("""
                ❌ Tool '\(toolName)' requires 'Programming project' flag.
                Open project settings → enable 'Programming project'.
                """)
            }
            if !settings.testsAccess.canRun {
                if settings.testsAccess == .readOnly {
                    return .denied("""
                    ❌ Tool '\(toolName)' is blocked: tests access is 'read-only'.
                    You can read logs via read_build_log, but cannot run tests.
                    Open project settings → Tests → set to 'Run' or 'Run + Write'.
                    """)
                }
                return .denied("""
                ❌ Tool '\(toolName)' is blocked: tests access is disabled.
                Open project settings → Tests → enable test access.
                """)
            }
            return .allowed
        }

        // read_build_log — available if tests at least at readOnly level.
        if toolName == "read_build_log" {
            if settings.isProgrammingProject && !settings.testsAccess.canReadLog {
                return .denied("""
                ❌ Tool 'read_build_log' is blocked: tests access is disabled.
                Open project settings → Tests → enable at least 'Read logs'.
                """)
            }
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
