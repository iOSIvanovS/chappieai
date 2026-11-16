// ChappieViewModel+MemoryEditor.swift
// Chappie
//
// Read and delete memory entries for the user-facing memory editor in Settings.
//
// WHY THIS LIVES IN THE VIEWMODEL, NOT THE VIEW:
// Deleting an entry changes the system prompt, so the cached prompt of the active thread has to
// be invalidated in the same moment. A view that talks to MemoryStore directly would leave the
// cache stale and the agent would keep following a rule the user just deleted, until the next
// memory write or a restart. Routing every delete through here keeps the two in step.
//
// RULE: an entry is always deleted as a whole — by key, never by a fragment of its JSON.
// Entries are the unit the system prompt reads (entry.promptDisplayValue), so partial edits
// would produce a record the agent never wrote and cannot reconcile.

import Foundation
import ChappieCore

extension ChappieViewModel {

    // MARK: - Read

    /// Entries of one scope, ready to display.
    ///
    /// `user_name` is filtered out of global memory: it is owned by the Name field in settings,
    /// and deleting it here would clear that setting as a side effect.
    func loadMemoryEntries(scope: MemoryScope) async -> [MemoryEntry] {
        guard let store = memoryStore else { return [] }

        let entries = (try? await store.readAllEntries(scope: scope.rawValue)) ?? []
        let visible = scope == .global
            ? entries.filter { $0.key != MemoryKeys.userName }
            : entries

        return MemoryEntryOrdering.sorted(visible)
    }

    // MARK: - Delete

    /// Deletes one entry and drops the cached system prompt of the active thread.
    ///
    /// Returns an error message for the UI, or nil on success.
    func deleteMemoryEntry(key: String, scope: MemoryScope) async -> String? {
        guard let store = memoryStore else { return "Storage is not connected." }

        do {
            try await store.deleteEntry(key: key, scope: scope.rawValue)
        } catch {
            return error.localizedDescription
        }

        // The prompt embeds every scope of the active thread, so any deletion can change it.
        // Invalidating unconditionally is cheaper than deciding which threads are affected,
        // and a needless rebuild only costs one local string assembly.
        invalidateActiveThreadSession()
        print("[ChappieViewModel] 🗑 Memory entry '\(key)' deleted from scope '\(scope.rawValue)'")
        return nil
    }
}
