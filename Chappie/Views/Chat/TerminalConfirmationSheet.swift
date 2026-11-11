// TerminalConfirmationSheet.swift
// Chappie
//
// Modal Run/Cancel prompt for a terminal command awaiting approval (thread terminal mode "confirm").
// Run needs a click or ⌘↩, never plain Enter: a dangerous command must not start by a stray keypress.
// Esc cancels.

import SwiftUI

struct TerminalConfirmationSheet: View {

    let prompt: TerminalPrompt
    let threadTitle: String?
    let onRun: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.orange)
                Text("terminal.confirmation_required")
                    .font(.system(size: 15, weight: .semibold))
            }

            if let threadTitle, !threadTitle.isEmpty {
                Text(threadTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ScrollView {
                Text(prompt.command)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 60, maxHeight: 220)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button(action: onRun) {
                    Label("Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled()
    }
}
