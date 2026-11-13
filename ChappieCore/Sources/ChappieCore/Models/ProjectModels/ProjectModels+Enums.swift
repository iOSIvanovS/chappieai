// ProjectModels+Enums.swift
// ChappieCore
//
// All project-related enums: roles, access levels, language.
// No localized UI strings here: labels live in the app target (ProjectModels+Display.swift).

import Foundation

// MARK: - AgentRole

/// Default: .advisor — safe read-only role.
/// Switching executor → advisor resets all access flags.
public enum AgentRole: String, Codable, Sendable, CaseIterable {
    case advisor
    case executor
}

// MARK: - GitAccessLevel

public enum GitAccessLevel: String, Codable, Sendable, CaseIterable {
    case none
    case statusOnly
    case write
    case full

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
