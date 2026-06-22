// ProjectChipsView+AddButton.swift
// Chappie
//
// Add project button and folder picker logic.

import SwiftUI
import AppKit

extension ProjectChipsView {

    // MARK: - Add button

    var addButton: some View {
        // Disabled while FS is syncing — opening a folder picker at this moment
        // would trigger another syncFileSystemForActiveThread() on top of the running one.
        let isLocked = isThinking || !isFileSystemReady

        return Button {
            openFolderPicker()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 5)
                .foregroundStyle(isLocked ? Color.secondary : Color.accentColor)
                .background(
                    Capsule()
                        .fill(Color(NSColor.controlBackgroundColor))
                        .overlay(Capsule().stroke(
                            isLocked ? Color.secondary.opacity(0.2) : Color.accentColor.opacity(0.35),
                            lineWidth: 1
                        ))
                )
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .shakeOnTap(isLocked: isThinking)
        .help(
            isThinking
                ? String(localized: "project.chips.add_locked_thinking")
                : (!isFileSystemReady ? String(localized: "project.chips.add_locked_loading") : String(localized: "project.chips.add_help"))
        )
    }

    // MARK: - Folder picker

    func openFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "project.chips.folder_picker_message")
        panel.prompt = String(localized: "project.chips.folder_picker_button")
        if panel.runModal() == .OK, let url = panel.url {
            onAddProject(url)
        }
    }
}
