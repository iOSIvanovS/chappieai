// ThreadListView.swift
// Chappie
//
// List of threads in the sidebar — main navigation element (IT-05).
// Classic view like Claude/ChatGPT: each thread is a row with title and date.
//
// ARCHITECTURE:
// - "Dumb" component — only displays data, all actions via callbacks.
// - Active thread highlighted via selectedThreadId.
// - orphanedThreadIds: threads whose provider/model was deleted get a ⚠️ indicator.

import SwiftUI
import ChappieCore

/// List of threads for the sidebar.
struct ThreadListView: View {

    // MARK: - Input

    let threads: [ThreadMetadata]
    let selectedThreadId: UUID?
    let orphanedThreadIds: Set<UUID>

    let onSelect: (ThreadMetadata) -> Void
    let onDelete: (ThreadMetadata) -> Void
    let onRename: (ThreadMetadata, String) -> Void

    // MARK: - State

    @State private var editingThreadId: UUID? = nil
    @State private var editingTitle: String = ""

    // MARK: - Body

    var body: some View {
        ForEach(threads) { thread in
            ThreadRowView(
                thread: thread,
                isSelected: thread.id == selectedThreadId,
                isEditing: editingThreadId == thread.id,
                isOrphaned: orphanedThreadIds.contains(thread.id),
                editingTitle: $editingTitle,
                onTap: {
                    onSelect(thread)
                },
                onCommitRename: {
                    let trimmed = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        onRename(thread, trimmed)
                    }
                    editingThreadId = nil
                },
                onCancelRename: {
                    editingThreadId = nil
                },
                onStartRename: {
                    editingTitle = thread.title
                    editingThreadId = thread.id
                },
                onDelete: {
                    onDelete(thread)
                }
            )
        }
    }
}
