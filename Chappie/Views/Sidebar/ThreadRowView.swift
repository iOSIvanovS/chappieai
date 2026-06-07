// ThreadRowView.swift
// Chappie
//
// One thread row in the sidebar.
// Shows title and action buttons.
//
// ORPHANED STATE:
// If the thread's provider or model was deleted, isOrphaned=true.
// A small ⚠️ icon is shown next to the title.
//
// HOVER ACTIONS (IT-12):
// On hover — only the trash (delete) button appears.
// Gear settings button was removed from hover — it was too small to hit reliably.
// Thread settings are accessible via:
//   1. Context menu (right-click) → "Thread Settings"
//   2. Thread name + gear chip in ProjectChipsView (always visible in chat)
//
// RENAME:
// Double-click or context menu "Rename" → inline TextField appears.
// Enter commits, Escape cancels.
//
// SOFT LOCK (isThinking):
// When AI is thinking — tap, delete, and context menu actions are disabled.
// Visual cue: row opacity reduced to 0.5, cursor shows "not allowed".
// This prevents race conditions: switching thread while AI writes to current one.

import SwiftUI
import ChappieCore

/// One thread row in the sidebar.
struct ThreadRowView: View {

    // MARK: - Input

    let thread: ThreadMetadata
    let isSelected: Bool
    let isEditing: Bool
    let isOrphaned: Bool
    /// When true — tap, delete, and settings are disabled (AI is responding).
    let isThinking: Bool
    @Binding var editingTitle: String

    let onTap: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onStartRename: () -> Void
    let onDelete: () -> Void
    let onOpenSettings: () -> Void

    // MARK: - State

    @State private var isHovered: Bool = false

    // MARK: - Body

    var body: some View {
        HStack(spacing: 6) {

            VStack(alignment: .leading, spacing: 2) {

                if isEditing {
                    TextField("thread.row.name_placeholder", text: $editingTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .onSubmit { onCommitRename() }
                        .onKeyPress(.escape) {
                            onCancelRename()
                            return .handled
                        }
                        .focused($isTextFieldFocused)
                        .onAppear { isTextFieldFocused = true }
                } else {
                    HStack(spacing: 4) {
                        Text(thread.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        // Orphaned indicator — provider/model was deleted
                        if isOrphaned {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.orange)
                                .help("thread.row.orphaned_help")
                        }
                    }
                }
            }

            Spacer()

            // Delete button — hidden while AI is thinking to prevent race conditions
            if (isHovered || isSelected) && !isEditing && !isThinking {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("thread.row.delete_help")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected
                      ? Color.accentColor
                      : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
        )
        // Tap is disabled while AI is thinking — prevents switching thread mid-response
        .onTapGesture {
            guard !isThinking else { return }
            onTap()
        }
        .onTapGesture(count: 2) {
            guard !isThinking else { return }
            onStartRename()
        }
        .onHover { isHovered = $0 }
        // Dimmed when locked — visual cue that row is not interactive
        .opacity(isThinking && !isSelected ? 0.5 : 1.0)
        .contextMenu {
            // Context menu items are individually disabled during thinking
            Button {
                guard !isThinking else { return }
                onStartRename()
            } label: {
                Label("thread.row.rename", systemImage: "pencil")
            }
            .disabled(isThinking)

            Button {
                guard !isThinking else { return }
                onOpenSettings()
            } label: {
                Label("thread.row.settings", systemImage: "gear")
            }
            .disabled(isThinking)

            Divider()

            Button(role: .destructive) {
                guard !isThinking else { return }
                onDelete()
            } label: {
                Label("thread.row.delete", systemImage: "trash")
            }
            .disabled(isThinking)
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .animation(.easeInOut(duration: 0.2), value: isThinking)
    }

    @FocusState private var isTextFieldFocused: Bool
}
