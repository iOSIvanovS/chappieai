// MemoryEntryOrdering.swift
// ChappieCore
//
// Display order for memory entries in the user-facing memory editor.
//
// WHY NOT STORAGE ORDER:
// Entries are appended in whatever order the agent happened to write them, so storage order
// is chronological and mixes types. A user looking for "the rule I want to delete" scans by
// type first, then by key — and the same order must hold on every screen, otherwise the list
// jumps around between openings. The system prompt already sorts by key inside a scope; this
// is the same idea with type as the outer level.

import Foundation

// MARK: - MemoryEntryOrdering

public enum MemoryEntryOrdering {

    /// Type first, then key, then the entry id as a final tie-breaker.
    ///
    /// WHY the id tie-breaker: two entries can share type and key only through a restored
    /// backup or a corrupt record. Without a stable last resort the order of those two would
    /// depend on the sort's stability, and Swift's sort is not guaranteed stable.
    public static func sorted(_ entries: [MemoryEntry]) -> [MemoryEntry] {
        entries.sorted { lhs, rhs in
            if lhs.type != rhs.type { return lhs.type < rhs.type }
            if lhs.key != rhs.key { return lhs.key < rhs.key }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
