// ProjectModels+Display.swift
// Chappie
//
// Localized UI labels for ChappieCore project enums. They live in the app target on purpose:
// Xcode extracts catalog keys only from the app's own sources, so keys used inside a Swift
// package look "stale" and get deleted, leaving raw dot-keys in the UI.

import Foundation
import ChappieCore

extension AgentRole {
    var displayName: String {
        switch self {
        case .advisor:  return String(localized: "role.advisor")
        case .executor: return String(localized: "role.executor")
        }
    }

    var description: String {
        switch self {
        case .advisor:  return String(localized: "role.advisor.description")
        case .executor: return String(localized: "role.executor.description")
        }
    }
}

extension GitAccessLevel {
    var displayName: String {
        switch self {
        case .none:       return String(localized: "git.access.none")
        case .statusOnly: return String(localized: "git.access.status_only")
        case .write:      return String(localized: "git.access.write")
        case .full:       return String(localized: "git.access.full")
        }
    }
}

extension TestsAccessLevel {
    var displayName: String {
        switch self {
        case .none:     return String(localized: "tests.access.none")
        case .readOnly: return String(localized: "tests.access.read_only")
        case .run:      return String(localized: "tests.access.run")
        case .write:    return String(localized: "tests.access.write")
        }
    }
}

extension DevEnvironment {
    /// UI label. Only `.unknown` needs translation; the rest are proper names.
    var localizedName: String {
        self == .unknown ? String(localized: "dev.env.unknown") : displayName
    }
}
