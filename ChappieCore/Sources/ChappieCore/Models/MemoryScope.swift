// MemoryScope.swift
// ChappieCore
//
// Canonical storage scope for the three-level memory system.
//
// WHY THIS TYPE EXISTS:
// A scope is a raw string in storage — either "global" or a UUID string. Thread memory and
// project memory both live under a UUID, so once stringified they are indistinguishable.
// Handing a project UUID where a thread UUID was meant reads a different (or empty) memory
// instead of failing, and the mistake surfaces as "the agent forgot everything" rather than
// as an error. The enum keeps the two apart at compile time; rawValue is the only place that
// knows the storage spelling.

import Foundation

// MARK: - MemoryScope

/// Where a memory entry lives.
///
/// The three levels are storage-equivalent (a string key into MemoryStorage.scopes) but
/// semantically distinct: global is shared by every thread, thread belongs to one thread,
/// project belongs to one project attachment of one thread.
public enum MemoryScope: Sendable, Hashable {

    /// Cross-project facts and rules, visible in every thread.
    case global

    /// Session context of one thread.
    case thread(UUID)

    /// Decisions and pipelines of one project attachment.
    ///
    /// NOTE: the UUID is ThreadProjectEntry.id, not a global project id — the same folder
    /// attached to two threads is two attachments with two separate memories.
    case project(UUID)

    /// Storage string for this scope.
    public var rawValue: String {
        switch self {
        case .global: return "global"
        case .thread(let id): return id.uuidString
        case .project(let id): return id.uuidString
        }
    }
}

// MARK: - MemoryKeys

/// Keys of memory entries that the app itself owns.
public enum MemoryKeys {

    /// The user's name, written by the Name field in settings and injected into the system prompt.
    ///
    /// WHY IT MATTERS: this entry is edited through a dedicated text field, so it must not appear
    /// in the memory editor — deleting it there would silently clear the setting instead of just
    /// removing something the agent remembered.
    public static let userName = "user_name"
}
