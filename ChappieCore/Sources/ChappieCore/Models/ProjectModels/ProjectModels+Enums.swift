// ProjectModels+Enums.swift
// ChappieCore
//
// All project-related enums: roles, access levels, language, dev environment.

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
    // git_push is available at .write and above — same level as git_commit.
    public var allowedTools: Set<String> {
        switch self {
        case .none:
            return []
        case .statusOnly:
            return ["git_status", "git_log"]
        case .write:
            return ["git_status", "git_log", "git_add", "git_commit", "git_push", "git_reset"]
        case .full:
            return ["git_status", "git_log", "git_add", "git_commit", "git_push", "git_reset",
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
    case english    = "english"
    case russian    = "ru"
    case german     = "de"
    case spanish    = "es"
    case french     = "fr"
    case hindi      = "hi"
    case japanese   = "ja"
    case portuguese = "pt-BR"
    case arabic     = "ar"
    case chinese    = "zh-Hans"

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
    // Static HTML/CSS/JS — no build system, no package manager.
    // Detected by index.html or .html files when no framework marker is present.
    case html            = "html"

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
        case .html:            return "HTML / CSS / JS"
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
        case .html:            return ["index.html", ".html", ".css", ".js"]
        }
    }

    /// Env-specific tools injected into the system prompt when this env is active.
    /// Universal tools (git, memory, web_fetch) are always injected regardless.
    /// HTML/CSS/JS has no dedicated build/test tools — run_terminal is sufficient.
    public var specificTools: [String] {
        switch self {
        case .unknown:         return []
        case .xcode:           return ["build_project", "run_tests", "read_build_log"]
        case .nodejs:          return ["build_project", "run_tests", "read_build_log"]
        case .python:          return ["run_tests", "read_build_log"]
        case .go:              return ["build_project", "run_tests", "read_build_log"]
        case .rust:            return ["build_project", "run_tests", "read_build_log"]
        case .java:            return ["build_project", "run_tests", "read_build_log"]
        case .kotlin:          return ["build_project", "run_tests", "read_build_log"]
        case .flutter:         return ["build_project", "run_tests", "read_build_log"]
        case .reacttypescript: return ["run_tests", "read_build_log"]
        case .dotnet:          return ["build_project", "run_tests", "read_build_log"]
        case .html:            return []
        }
    }
}
