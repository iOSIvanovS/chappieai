// ProjectChipsView.swift
// Chappie
//
// Horizontal row of project chips for the current thread.
// Displayed as a floating rounded pill above the message list.
//
// CHIP STYLE:
//   Only the inner HStack (label + chips + add button) gets ultraThinMaterial pill background.
//   Outer HStack has Spacer() so the pill hugs its content on the left.
//   Consistent with ModelPickerRow and the bottom InputMorphView panel.
//
// IT-09: Tap on chip opens ProjectSettingsSheet.
// onOpenSettings(UUID) callback passes project ID to ViewModel.
//
// ARCHITECTURE (IT-01 + IT-06):
// Chips show ProjectMetadata from ProjectStore.
// On add — ProjectEntity is created in ProjectStore, UUID added to ThreadEntity.projectBindingsJSON.
// On remove — UUID removed from projectBindingsJSON (ProjectEntity is NOT deleted).
//
// DUMB COMPONENT PRINCIPLE:
// ProjectChipsView has no direct knowledge of SwiftData, ProjectStore or ThreadStore.
// All data via parameters, all actions via callbacks. Logic lives in ChappieViewModel.

import SwiftUI
import ChappieCore

// MARK: - ProjectChipsView

/// Horizontal row of project chips for the current thread.
///
/// Shows projects bound to the thread.
/// "+" button adds a new project via NSOpenPanel.
/// "×" button on each chip removes the project from the thread.
/// Tap on chip opens project settings (IT-09).
struct ProjectChipsView: View {

    // MARK: - Input

    let projects: [ProjectMetadata]

    // MARK: - Callbacks

    /// Called when the user taps "+" and selects a folder.
    let onAddProject: (URL) -> Void

    /// Called when the user taps "×" on a chip.
    let onRemoveProject: (UUID) -> Void

    /// Called when the user taps a chip to open settings (IT-09).
    let onOpenSettings: (UUID) -> Void

    // MARK: - Local state

    /// Hover state per chip — key is project UUID.
    @State private var hoveredProjectId: UUID? = nil

    // MARK: - Body

    var body: some View {
        // Outer HStack: pill on the left, Spacer pushes it to hug content width.
        // Same pattern as ModelPickerRow — no ScrollView, just a plain HStack.
        HStack(spacing: 0) {
            // Inner pill: hugs content naturally via fixedSize
            HStack(spacing: 6) {

                // "Проекты" label
                Text("Проекты")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color(NSColor.textBackgroundColor).opacity(0.6))
                    )

                // Chips + add button — plain HStack, same as ModelPickerRow inner layout
                HStack(spacing: 6) {
                    ForEach(projects) { project in
                        projectChip(for: project)
                    }
                    addButton
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            // Material only on the pill, not on the full-width row
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)

            Spacer()
        }
    }

    // MARK: - Project chip

    /// Individual chip for one project.
    ///
    /// HOVER BEHAVIOUR:
    /// On hover — the "×" button appears to the right of the name.
    ///
    /// TAP BEHAVIOUR (IT-09):
    /// Tap → onOpenSettings(project.id) → parent shows ProjectSettingsSheet.
    /// "×" on hover — removes project from thread (does not open settings).
    private func projectChip(for project: ProjectMetadata) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.accentColor.opacity(0.8))

            Text(project.displayName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary)

            // Role indicator (IT-09) — small icon shows current agent role
            roleIndicator(for: project.settings.agentRole)

            if hoveredProjectId == project.id {
                Button {
                    onRemoveProject(project.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color(NSColor.textBackgroundColor).opacity(0.6))
        )
        .overlay(
            Capsule()
                .stroke(Color.accentColor.opacity(0.2), lineWidth: 0.5)
        )
        .onHover { isHovered in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredProjectId = isHovered ? project.id : nil
            }
        }
        .onTapGesture {
            // Tap on chip → open project settings (IT-09)
            onOpenSettings(project.id)
        }
        .help("Проект: \(project.displayName) (\(project.settings.agentRole.displayName))\nТап — настройки, × — убрать из треда")
    }

    /// Small agent role indicator next to the project name.
    ///
    /// WHY:
    /// User should immediately see in which mode the agent works with each project.
    /// Lock icon = advisor (read-only), bolt icon = executor.
    @ViewBuilder
    private func roleIndicator(for role: AgentRole) -> some View {
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

    // MARK: - Add button

    private var addButton: some View {
        Button {
            openFolderPicker()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text("Добавить")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(Color.accentColor)
            .background(
                Capsule()
                    .fill(Color(NSColor.textBackgroundColor).opacity(0.6))
                    .overlay(
                        Capsule()
                            .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .help("Добавить папку проекта к этому треду")
    }

    // MARK: - Private helpers

    private func openFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Выберите папку проекта для добавления в тред"
        panel.prompt = "Добавить"

        if panel.runModal() == .OK, let url = panel.url {
            onAddProject(url)
        }
    }
}

// MARK: - Preview

#Preview("С проектами") {
    ProjectChipsView(
        projects: [
            ProjectMetadata(
                id: UUID(),
                displayName: "Chappie",
                settings: ProjectSettings(agentRole: .executor, isProgrammingProject: true)
            ),
            ProjectMetadata(
                id: UUID(),
                displayName: "MyApp",
                settings: ProjectSettings(agentRole: .advisor)
            )
        ],
        onAddProject: { url in
            print("Добавить: \(url.lastPathComponent)")
        },
        onRemoveProject: { id in
            print("Удалить: \(id)")
        },
        onOpenSettings: { id in
            print("Настройки: \(id)")
        }
    )
    .padding()
    .background(Color(NSColor.windowBackgroundColor))
}

#Preview("Пустой список") {
    ProjectChipsView(
        projects: [],
        onAddProject: { _ in },
        onRemoveProject: { _ in },
        onOpenSettings: { _ in }
    )
    .padding()
    .background(Color(NSColor.windowBackgroundColor))
}
