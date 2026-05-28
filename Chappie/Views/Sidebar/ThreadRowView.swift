// ThreadRowView.swift
// Chappie
//
// One thread row in the sidebar.
// Shows title, relative date, and action buttons.
//
// ORPHANED STATE:
// If the thread's provider or model was deleted, isOrphaned=true.
// A small ⚠️ icon is shown next to the title.
//
// HOVER ACTIONS (IT-12):
// On hover — only the trash (delete) button appears.
// Gear settings button was removed from hover — it was too small to hit reliably.
// Thread settings are accessible via:
//   1. Context menu (right-click) → "Настройки треда"
//   2. Thread name + gear chip in ProjectChipsView (always visible in chat)
//
// RENAME:
// Double-click or context menu "Rename" → inline TextField appears.
// Enter commits, Escape cancels.

import SwiftUI
import ChappieCore

/// One thread row in the sidebar.
struct ThreadRowView: View {

    // MARK: - Input

    let thread: ThreadMetadata
    let isSelected: Bool
    let isEditing: Bool
    let isOrphaned: Bool
    @Binding var editingTitle: String

    let onTap: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onStartRename: () -> Void
    let onDelete: () -> Void
    let onOpenSettings: () -> Void

    // MARK: - State

    @State private var isHovered: Bool = false

    // MARK: - Date Formatter

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.locale = Locale(identifier: "ru_RU")
        return f
    }()

    private var relativeDate: String {
        Self.relativeDateFormatter.localizedString(for: thread.updatedAt, relativeTo: Date())
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 6) {

            VStack(alignment: .leading, spacing: 2) {

                if isEditing {
                    TextField("Название треда", text: $editingTitle)
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
                                .help("Провайдер или модель этого треда были удалены")
                        }
                    }
                }

                Text(relativeDate)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary)
            }

            Spacer()

            // On hover — only delete button.
            // Gear was removed (IT-12): too small to hit in the row.
            // Settings are in context menu and in the ProjectChipsView chip.
            if (isHovered || isSelected) && !isEditing {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Удалить тред")
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
        .onTapGesture { onTap() }
        .onTapGesture(count: 2) { onStartRename() }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button {
                onStartRename()
            } label: {
                Label("Переименовать", systemImage: "pencil")
            }
            Button {
                onOpenSettings()
            } label: {
                Label("Настройки треда", systemImage: "gear")
            }
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Удалить", systemImage: "trash")
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    @FocusState private var isTextFieldFocused: Bool
}
