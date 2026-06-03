// ProjectModels.swift
// ChappieCore
//
// SwiftData entity + Codable settings for projects.
// Security-scoped bookmark persists sandbox access across app restarts.
// ProjectSettings serialized to JSON in ProjectEntity.settingsJSON.

import Foundation
import SwiftData

// MARK: - ProjectEntity

/// SwiftData record: one project = one workspace folder + settings.
/// A project can be attached to multiple threads simultaneously.
@Model
public final class ProjectEntity {

    public var id: UUID
    public var displayName: String
    public var bookmarkData: Data   // security-scoped bookmark, not a raw path
    public var createdAt: Date
    public var settingsJSON: Data   // encoded ProjectSettings

    public init(
        id: UUID = UUID(),
        displayName: String,
        bookmarkData: Data,
        settings: ProjectSettings = ProjectSettings()
    ) {
        self.id = id
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.createdAt = Date()
        self.settingsJSON = (try? JSONEncoder().encode(settings)) ?? Data()
    }
}

// MARK: - AgentRole

/// Default: .advisor — safe read-only role.
/// Switching executor → advisor resets all access flags.
public enum AgentRole: String, Codable, Sendable, CaseIterable {
    case advisor
    case executor

    public var displayName: String {
        switch self {
        case .advisor:  return "Советник"
        case .executor: return "Исполнитель"
        }
    }

    public var description: String {
        switch self {
        case .advisor:
            return "Читает файлы, даёт советы и сниппеты. Изменения вносит пользователь."
        case .executor:
            return "Самостоятельно работает с файлами, git и инструментами."
        }
    }
}

// MARK: - GitAccessLevel

public enum GitAccessLevel: String, Codable, Sendable, CaseIterable {
    case none
    case statusOnly
    case write
    case full

    public var displayName: String {
        switch self {
        case .none:       return "Нет доступа"
        case .statusOnly: return "Только чтение (status, log)"
        case .write:      return "Запись (add, commit)"
        case .full:       return "Полный доступ"
        }
    }

    // git_diff is NEVER allowed — it loads entire project into AI context (costs money).
    public var allowedTools: Set<String> {
        switch self {
        case .none:
            return []
        case .statusOnly:
            return ["git_status", "git_log"]
        case .write:
            return ["git_status", "git_log", "git_add", "git_commit", "git_reset"]
        case .full:
            return ["git_status", "git_log", "git_add", "git_commit", "git_reset",
                    "git_revert", "git_checkout"]
        }
    }
}

// MARK: - TestsAccessLevel

public enum TestsAccessLevel: String, Codable, Sendable, CaseIterable {
    case none
    case readOnly
    case run
    case write

    public var displayName: String {
        switch self {
        case .none:     return "Нет доступа"
        case .readOnly: return "Только чтение логов"
        case .run:      return "Запуск тестов"
        case .write:    return "Запуск + создание тестов"
        }
    }

    public var canRun: Bool { self == .run || self == .write }
    public var canWrite: Bool { self == .write }
    public var canReadLog: Bool { self != .none }
}

// MARK: - TerminalAccessLevel

/// Controls how the AI can use run_terminal.
///
/// WHY THREE LEVELS:
/// - none: terminal is completely off (default, safe).
/// - confirm: every command requires explicit user confirmation before execution.
/// - auto: commands run immediately. User chose to trust the agent fully.
///
/// There is no "safe commands only" auto-mode — the boundary between safe and dangerous
/// is too fuzzy in practice (e.g. `npm install` can run postinstall scripts).
/// Better to give the user a clear binary choice: confirm everything or trust fully.
public enum TerminalAccessLevel: String, Codable, Sendable, CaseIterable {
    case none
    case confirm
    case auto

    public var displayName: String {
        switch self {
        case .none:    return "Нет доступа"
        case .confirm: return "С подтверждением"
        case .auto:    return "Автоматически"
        }
    }

    public var description: String {
        switch self {
        case .none:
            return "Терминал недоступен агенту."
        case .confirm:
            return "Каждая команда требует подтверждения в чате перед выполнением."
        case .auto:
            return "Агент выполняет команды без подтверждения. Используй только если доверяешь агенту полностью."
        }
    }

    public var isEnabled: Bool { self != .none }
    public var requiresConfirmation: Bool { self == .confirm }
}

// MARK: - ProjectLanguage

public enum ProjectLanguage: String, Codable, Sendable, CaseIterable {
    case english
    case native

    public var displayName: String {
        switch self {
        case .english: return "Английский"
        case .native:  return "Родной язык пользователя"
        }
    }
}

// MARK: - ProjectSettings

/// Agent rights and configuration for a project. Serialized to JSON in ProjectEntity.
/// Safe defaults: agentRole = .advisor, everything else = off/none.
public struct ProjectSettings: Codable, Sendable, Equatable, Hashable {

    public var agentRole: AgentRole
    public var preferredLanguage: String?

    // Unlocks git/tests/architecture/comments/terminal settings in the UI and prompt.
    public var isProgrammingProject: Bool

    public var gitAccess: GitAccessLevel
    public var testsAccess: TestsAccessLevel
    public var architectureEnabled: Bool
    public var architectureLanguage: ProjectLanguage
    public var commentsEnabled: Bool
    public var commentsLanguage: ProjectLanguage
    public var terminalAccess: TerminalAccessLevel

    public init(
        agentRole: AgentRole = .advisor,
        preferredLanguage: String? = nil,
        isProgrammingProject: Bool = false,
        gitAccess: GitAccessLevel = .none,
        testsAccess: TestsAccessLevel = .none,
        architectureEnabled: Bool = false,
        architectureLanguage: ProjectLanguage = .english,
        commentsEnabled: Bool = false,
        commentsLanguage: ProjectLanguage = .english,
        terminalAccess: TerminalAccessLevel = .none
    ) {
        self.agentRole = agentRole
        self.preferredLanguage = preferredLanguage
        self.isProgrammingProject = isProgrammingProject
        self.gitAccess = gitAccess
        self.testsAccess = testsAccess
        self.architectureEnabled = architectureEnabled
        self.architectureLanguage = architectureLanguage
        self.commentsEnabled = commentsEnabled
        self.commentsLanguage = commentsLanguage
        self.terminalAccess = terminalAccess
    }

    /// Resets all access flags when downgrading to advisor role.
    public mutating func downgradeToAdvisor() {
        agentRole = .advisor
        gitAccess = .none
        testsAccess = .none
        architectureEnabled = false
        commentsEnabled = false
        terminalAccess = .none
    }
}

// MARK: - ProjectSettings: System Prompt Formatting

extension ProjectSettings {

    public func formatForSystemPrompt(projectName: String) -> String {
        var lines: [String] = ["## Project Settings: \(projectName)"]

        lines.append("- Role: \(agentRole.rawValue.uppercased())")

        if agentRole == .advisor {
            lines.append("- Access: read-only (list_files, read_file). All write/git/test/terminal tools are BLOCKED.")
            lines.append("- To unlock tools: go to project settings → change role to Executor.")
            return lines.joined(separator: "\n")
        }

        lines.append("- Programming project: \(isProgrammingProject ? "yes" : "no")")

        if isProgrammingProject {
            if gitAccess == .none {
                lines.append("- Git: BLOCKED (enable in project settings)")
            } else {
                let toolsList = gitAccess.allowedTools.sorted().joined(separator: ", ")
                lines.append("- Git: \(gitAccess.rawValue) [\(toolsList)] [git_diff: ALWAYS FORBIDDEN]")
            }

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

            if architectureEnabled {
                lines.append("- Architecture files: enabled (\(architectureLanguage.rawValue)). Discuss file paths with user before creating. If architecture files are found, save their paths to project memory and use them as a reference during development when relevant. You are required to keep architecture files up to date after code changes that affect the described structure. Keep architecture files concise: describe structure and decisions, not implementation details. Remove sections that are no longer relevant — dead history belongs in git, not in architecture files.")
            } else {
                lines.append("- Architecture files: read-only (enable write in project settings)")
            }

            if commentsEnabled {
                lines.append("- Code comments: enabled (\(commentsLanguage.rawValue)). Be concise — explain WHY, not WHAT. Write only when the code is non-obvious. Delete comments that are outdated or describe obvious operations. Never let comments outnumber or outsize the code they describe.")
            } else {
                lines.append("- Code comments: DISABLED (enable in project settings)")
            }

            switch terminalAccess {
            case .none:
                lines.append("- Terminal: BLOCKED (enable in project settings)")
            case .confirm:
                // Remind the agent that it must ask before executing — the confirmation
                // mechanism is enforced in the tool itself, but the prompt reinforces it.
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

// MARK: - ProjectEntity Helpers

extension ProjectEntity {

    /// Decodes settings from JSON. Returns safe defaults on failure.
    public var settings: ProjectSettings {
        guard !settingsJSON.isEmpty,
              let decoded = try? JSONDecoder().decode(ProjectSettings.self, from: settingsJSON)
        else {
            return ProjectSettings()
        }
        return decoded
    }

    /// Resolves the security-scoped bookmark to a workspace URL.
    /// Caller MUST call url.stopAccessingSecurityScopedResource() when done.
    public func resolveWorkspaceURL() -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            print("[ProjectModels] ⚠️ Failed to resolve bookmark for '\(displayName)'")
            return nil
        }

        if isStale {
            print("[ProjectModels] ⚠️ Stale bookmark for '\(displayName)'. Re-authorization needed.")
        }

        return url
    }
}

// MARK: - ProjectMetadata

/// Sendable DTO for passing project data across the actor boundary.
///
/// isUnavailable: runtime-only flag, NOT persisted in SwiftData.
/// Set to true by syncFileSystemForActiveThread() when the folder is missing or in Trash.
/// Cleared to false when the folder becomes accessible again on next sync.
/// WHY: ProjectStore is the source of truth for persistent data — transient
/// availability state lives only in the ViewModel's activeProjects array.
public struct ProjectMetadata: Sendable, Identifiable, Hashable {

    public let id: UUID
    public let displayName: String
    public let createdAt: Date
    public let settings: ProjectSettings

    /// Runtime-only: true when the project folder is missing, in Trash, or otherwise inaccessible.
    /// Not stored in SwiftData — re-evaluated on every syncFileSystemForActiveThread() call.
    public var isUnavailable: Bool

    /// Internal init from entity — stays inside the actor.
    init(from entity: ProjectEntity) {
        self.id = entity.id
        self.displayName = entity.displayName
        self.createdAt = entity.createdAt
        self.settings = entity.settings
        self.isUnavailable = false
    }

    /// Public init for Previews, tests, and direct construction.
    public init(
        id: UUID = UUID(),
        displayName: String,
        createdAt: Date = Date(),
        settings: ProjectSettings = ProjectSettings(),
        isUnavailable: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.settings = settings
        self.isUnavailable = isUnavailable
    }
}
