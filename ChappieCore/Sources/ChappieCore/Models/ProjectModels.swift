// ProjectModels.swift
// ChappieCore
//
// Domain models for projects.
//
// STORAGE:
// All project data is stored via ChappieDataStore — the only place that knows about SwiftData.
// ProjectPayload (defined in ProjectStore.swift) is the persisted Codable struct.
// Security-scoped bookmarks are stored separately under Relation.projectBookmark(uuid).
// ChappieDataStore is the ONLY place that knows about SwiftData — see DataStore.swift.
//
// CODABLE COMPATIBILITY CONTRACT (never violate — stored JSON must always decode cleanly):
//   1. Never rename a stored property without adding/updating CodingKeys.
//   2. Never remove a stored property — mark optional with a default instead.
//   3. Always give new properties a default value so old records decode cleanly.

import Foundation

// MARK: - AgentRole

/// Default: .advisor — safe read-only role.
/// Switching executor → advisor resets all access flags.
public enum AgentRole: String, Codable, Sendable, CaseIterable {
    case advisor
    case executor

    public var displayName: String {
        switch self {
        case .advisor:  return NSLocalizedString("role.advisor", bundle: .main, comment: "")
        case .executor: return NSLocalizedString("role.executor", bundle: .main, comment: "")
        }
    }

    public var description: String {
        switch self {
        case .advisor:
            return NSLocalizedString("role.advisor.description", bundle: .main, comment: "")
        case .executor:
            return NSLocalizedString("role.executor.description", bundle: .main, comment: "")
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
        case .none:       return NSLocalizedString("git.access.none", bundle: .main, comment: "")
        case .statusOnly: return NSLocalizedString("git.access.status_only", bundle: .main, comment: "")
        case .write:      return NSLocalizedString("git.access.write", bundle: .main, comment: "")
        case .full:       return NSLocalizedString("git.access.full", bundle: .main, comment: "")
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
        case .none:     return NSLocalizedString("tests.access.none", bundle: .main, comment: "")
        case .readOnly: return NSLocalizedString("tests.access.read_only", bundle: .main, comment: "")
        case .run:      return NSLocalizedString("tests.access.run", bundle: .main, comment: "")
        case .write:    return NSLocalizedString("tests.access.write", bundle: .main, comment: "")
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
        case .none:    return NSLocalizedString("terminal.access.none", bundle: .main, comment: "")
        case .confirm: return NSLocalizedString("terminal.access.confirm", bundle: .main, comment: "")
        case .auto:    return NSLocalizedString("terminal.access.auto", bundle: .main, comment: "")
        }
    }

    public var description: String {
        switch self {
        case .none:
            return NSLocalizedString("terminal.access.none.description", bundle: .main, comment: "")
        case .confirm:
            return NSLocalizedString("terminal.access.confirm.description", bundle: .main, comment: "")
        case .auto:
            return NSLocalizedString("terminal.access.auto.description", bundle: .main, comment: "")
        }
    }

    public var isEnabled: Bool { self != .none }
    public var requiresConfirmation: Bool { self == .confirm }
}

// MARK: - ProjectLanguage

/// Language for architecture files and code comments.
/// rawValue is stored in JSON — never rename cases without a migration.
/// "english" and "native" are legacy rawValues kept for Codable compatibility with old records.
/// All new cases use language-code rawValues (e.g. "ru", "de") that AI reads directly in the prompt.
public enum ProjectLanguage: String, Codable, Sendable, CaseIterable {
    // Legacy cases — kept for backward Codable compatibility.
    // "english" maps to English, "native" was "user's native language" (now deprecated).
    case english = "english"
    case russian = "ru"
    case german  = "de"
    case spanish = "es"
    case french  = "fr"
    case hindi   = "hi"
    case japanese = "ja"
    case portuguese = "pt-BR"
    case arabic  = "ar"
    case chinese = "zh-Hans"

    // "native" stored in old records decodes to nil → falls back to default (.english) via migration.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Map legacy "native" to .english (closest safe default).
        self = ProjectLanguage(rawValue: raw) ?? .english
    }

    /// Human-readable name shown in the picker — always in the target language itself.
    public var displayName: String {
        switch self {
        case .english:    return "English"
        case .russian:    return "Русский"
        case .german:     return "Deutsch"
        case .spanish:    return "Español"
        case .french:     return "Français"
        case .hindi:      return "हिन्दी"
        case .japanese:   return "日本語"
        case .portuguese: return "Português (BR)"
        case .arabic:     return "العربية"
        case .chinese:    return "中文（简体）"
        }
    }

    /// Value injected into the system prompt — AI reads this directly.
    public var promptValue: String {
        switch self {
        case .english:    return "english"
        case .russian:    return "Russian"
        case .german:     return "German"
        case .spanish:    return "Spanish"
        case .french:     return "French"
        case .hindi:      return "Hindi"
        case .japanese:   return "Japanese"
        case .portuguese: return "Portuguese (Brazilian)"
        case .arabic:     return "Arabic"
        case .chinese:    return "Chinese (Simplified)"
        }
    }
}

// MARK: - DevEnvironment

/// Development environment / language stack for a programming project.
/// Controls which env-specific tools are injected into the system prompt.
/// .unknown means not yet detected or selected.
public enum DevEnvironment: String, Codable, Sendable, CaseIterable {
    case unknown         = "unknown"
    case xcode           = "xcode"
    case nodejs          = "nodejs"
    case python          = "python"
    case go              = "go"
    case rust            = "rust"
    case java            = "java"
    case kotlin          = "kotlin"
    case flutter         = "flutter"
    case reacttypescript = "react_typescript"
    case dotnet          = "dotnet"

    public var displayName: String {
        switch self {
        case .unknown:         return NSLocalizedString("dev.env.unknown", bundle: .main, comment: "")
        case .xcode:           return "Xcode (Swift / Obj-C)"
        case .nodejs:          return "Node.js"
        case .python:          return "Python"
        case .go:              return "Go"
        case .rust:            return "Rust"
        case .java:            return "Java"
        case .kotlin:          return "Kotlin (Android)"
        case .flutter:         return "Flutter (Dart)"
        case .reacttypescript: return "React / TypeScript"
        case .dotnet:          return ".NET (C#)"
        }
    }

    /// Marker files used by AI to auto-detect the environment from a file list.
    public var detectionHints: [String] {
        switch self {
        case .unknown:         return []
        case .xcode:           return [".xcodeproj", ".xcworkspace", ".swift"]
        case .nodejs:          return ["package.json", "node_modules", ".nvmrc"]
        case .python:          return ["requirements.txt", "pyproject.toml", "setup.py", ".py"]
        case .go:              return ["go.mod", "go.sum", ".go"]
        case .rust:            return ["Cargo.toml", "Cargo.lock", ".rs"]
        case .java:            return ["pom.xml", "build.gradle", ".java"]
        case .kotlin:          return ["build.gradle.kts", "AndroidManifest.xml", ".kt"]
        case .flutter:         return ["pubspec.yaml", "pubspec.lock", ".dart"]
        case .reacttypescript: return ["tsconfig.json", "vite.config.ts", "next.config.ts", ".tsx"]
        case .dotnet:          return [".csproj", ".sln", ".cs"]
        }
    }

    /// Env-specific tools injected into the system prompt when this env is active.
    /// Universal tools (git, memory, web_fetch) are always injected regardless.
    public var specificTools: [String] {
        switch self {
        case .unknown:
            return []
        case .xcode:
            return ["build_project", "run_tests", "read_build_log"]
        case .nodejs:
            return ["build_project", "run_tests", "read_build_log"]
        case .python:
            return ["run_tests", "read_build_log"]
        case .go:
            return ["build_project", "run_tests", "read_build_log"]
        case .rust:
            return ["build_project", "run_tests", "read_build_log"]
        case .java:
            return ["build_project", "run_tests", "read_build_log"]
        case .kotlin:
            return ["build_project", "run_tests", "read_build_log"]
        case .flutter:
            return ["build_project", "run_tests", "read_build_log"]
        case .reacttypescript:
            return ["run_tests", "read_build_log"]
        case .dotnet:
            return ["build_project", "run_tests", "read_build_log"]
        }
    }
}

// MARK: - ProjectSettings

/// Agent rights and configuration for a project. Serialized to JSON inside ProjectPayload.settingsJSON.
/// Safe defaults: agentRole = .advisor, everything else = off/none.
public struct ProjectSettings: Codable, Sendable, Equatable, Hashable {

    public var agentRole: AgentRole

    // Unlocks git/tests/architecture/comments/terminal settings in the UI and prompt.
    public var isProgrammingProject: Bool

    // Dev environment — controls env-specific tool injection. .unknown = not set.
    public var devEnvironment: DevEnvironment

    public var gitAccess: GitAccessLevel
    public var testsAccess: TestsAccessLevel
    public var architectureEnabled: Bool
    public var architectureLanguage: ProjectLanguage
    public var commentsEnabled: Bool
    public var commentsLanguage: ProjectLanguage
    public var terminalAccess: TerminalAccessLevel

    public init(
        agentRole: AgentRole = .advisor,
        isProgrammingProject: Bool = false,
        devEnvironment: DevEnvironment = .unknown,
        gitAccess: GitAccessLevel = .none,
        testsAccess: TestsAccessLevel = .none,
        architectureEnabled: Bool = false,
        architectureLanguage: ProjectLanguage = .english,
        commentsEnabled: Bool = false,
        commentsLanguage: ProjectLanguage = .english,
        terminalAccess: TerminalAccessLevel = .none
    ) {
        self.agentRole = agentRole
        self.isProgrammingProject = isProgrammingProject
        self.devEnvironment = devEnvironment
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
                lines.append("- Terminal: BLOCKED (enable in project settings)")
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

// MARK: - ProjectMetadata

/// Sendable DTO for passing project data across the actor boundary.
///
/// isUnavailable: runtime-only flag, NOT persisted in ChappieDataStore.
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
    /// Not stored — re-evaluated on every syncFileSystemForActiveThread() call.
    public var isUnavailable: Bool

    /// Runtime-only: absolute path resolved from security-scoped bookmark.
    /// Set by syncFileSystemForActiveThread() after successful bookmark resolution.
    /// Not stored — re-evaluated on every sync. Nil until first successful resolution.
    public var absolutePath: String?

    /// Public init for Previews, tests, and direct construction.
    public init(
        id: UUID = UUID(),
        displayName: String,
        createdAt: Date = Date(),
        settings: ProjectSettings = ProjectSettings(),
        isUnavailable: Bool = false,
        absolutePath: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.settings = settings
        self.isUnavailable = isUnavailable
        self.absolutePath = absolutePath
    }
}
