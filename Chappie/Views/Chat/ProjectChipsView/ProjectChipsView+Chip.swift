// ProjectChipsView+Chip.swift
// Chappie
//
// Project chip, role indicator, and help text.

import SwiftUI
import ChappieCore

extension ProjectChipsView {

    // MARK: - Project chip

    func projectChip(for project: ProjectMetadata) -> some View {
        let isInteractive = !isThinking && isFileSystemReady
        let showRemove = !isThinking && isFileSystemReady

        return HStack(spacing: 4) {
            if !isFileSystemReady {
                // Spinner while FS is syncing.
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.55)
                    .frame(width: 10, height: 10)
            } else {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor.opacity(0.8))
            }

            Text(project.displayName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            roleIndicator(for: project.settings.agentRole)

            if showRemove {
                Button {
                    onRemoveProject(project.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color(NSColor.controlBackgroundColor)))
        .overlay(Capsule().stroke(Color.accentColor.opacity(isFileSystemReady ? 0.2 : 0.08), lineWidth: 0.5))
        .onTapGesture {
            if isInteractive { onOpenSettings(project.id) }
        }
        .shakeOnTap(isLocked: isThinking)
        .help(helpText(for: project))
    }

    // MARK: - Chip help text

    func helpText(for project: ProjectMetadata) -> String {
        if !isFileSystemReady {
            return String(localized: "project.chips.add_locked_loading")
        }
        let removeHint = isThinking ? "" : String(localized: "project.chips.chip_hint_remove")
        return String(format: String(localized: "project.chips.chip_hint"), project.displayName, project.settings.agentRole.displayName, removeHint)
    }

    // MARK: - Role indicator

    @ViewBuilder
    func roleIndicator(for role: AgentRole) -> some View {
        switch role {
        case .advisor:
            Image(systemName: "lock.fill")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        case .executor:
            Image(systemName: "bolt.fill")
                .font(.system(size: 8))
                .foregroundStyle(Color.accentColor.opacity(0.7))
        }
    }
}
