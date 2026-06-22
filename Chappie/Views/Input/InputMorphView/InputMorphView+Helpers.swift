// InputMorphView+Helpers.swift
// Chappie
//
// Private actions: send trigger and file picker.

import SwiftUI
import AppKit

extension InputMorphView {

    // MARK: - Helpers

    func triggerSend() {
        let pending = attachments
        onSend(pending)
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            attachments = []
        }
    }

    func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "input.file_picker_message")
        panel.prompt = String(localized: "input.file_picker_button")

        guard panel.runModal() == .OK else { return }

        let newFiles = panel.urls.compactMap { AttachedFile.load(from: $0) }
        let existingNames = Set(attachments.map(\.filename))
        let unique = newFiles.filter { !existingNames.contains($0.filename) }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            attachments.append(contentsOf: unique)
        }
    }
}
