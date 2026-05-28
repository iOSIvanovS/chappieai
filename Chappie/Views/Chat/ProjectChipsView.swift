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
// THREAD SETTINGS CHIP (IT-12):
//   Right-side pill shows thread name + gear icon.
//   Pattern: "⚙ <thread name>" — user sees which thread is active AND can open settings.
//   Replaces the anonymous gear icon from IT-11.
//   Tap → onOpenThreadSettings() → ContentView shows ThreadSettingsSheet.
//   Thread title is truncated to fit; full name shown in tooltip.
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
/// Thread name + gear pill on the right opens thread settings (IT-12).
struct ProjectChipsView: View {

    // MARK: - Input

    let projects: [ProjectMetadata]

    /// Active thread name — shown in the right-side settings chip.
    let threadName: String?

    // MARK: - Callbacks

    /// Called when the user taps "+" and selects a folder.
    let onAddProject: (URL) -> Void

    /// Called when the user taps "×" on a chip.
    let onRemoveProject: (UUID) -> Void

    /// Called when the user taps a chip to open project settings (IT-09).
    let onOpenSettings: (UUID) -> Void

    /// Called when the user taps the thread settings chip to open thread settings.
    let onOpenThreadSettings: () -> Void

    // MARK: - Local state

    /// Hover state per chip — key is project UUID.
    @State private var hoveredProjectId: UUID? = nil

    // MARK: - Body

    var body: some View {
        // Full-width HStack: projects pill on the left, thread settings chip on the right.
        // Same pattern as ModelPickerRow (model selector left, balance pill right).
        HStack(spacing: 8) {

            // Left: projects pill — hugs content naturally via fixedSize
            HStack(spacing: 6) {

                // "Проекты" label
                Text("Проекты")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(.white)
                    )

                // Chips + add button
                HStack(spacing: 6) {
                    ForEach(projects) { project in
                        projectChip(for: project)
                    }
                    addButton
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Spacer()

            // Right: thread name + gear chip — mirrors balance pill in ModelPickerRow.
            // Shows the active thread name so user always knows which thread is open.
            Button(action: onOpenThreadSettings) {
                HStack(spacing: 5) {
                    Image(systemName: "gear")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    if let name = threadName, !name.isEmpty {
                        Text(name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 160)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .help(threadName.map { "Настройки треда «\($0)»" } ?? "Настройки треда")
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
                .fill(.white)
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
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 5)
                .foregroundStyle(Color.accentColor)
                .background(
                    Capsule()
                        .fill(.white)
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
        threadName: "Разработка Chappie",
        onAddProject: { url in
            print("Добавить: \(url.lastPathComponent)")
        },
        onRemoveProject: { id in
            print("Удалить: \(id)")
        },
        onOpenSettings: { id in
            print("Настройки проекта: \(id)")
        },
        onOpenThreadSettings: {
            print("Настройки треда")
        }
    )
    .padding()
    .background(Color(NSColor.windowBackgroundColor))
}

#Preview("Пустой список") {
    ProjectChipsView(
        projects: [],
        threadName: "Новый тред",
        onAddProject: { _ in },
        onRemoveProject: { _ in },
        onOpenSettings: { _ in },
        onOpenThreadSettings: {}
    )
    .padding()
    .background(Color(NSColor.windowBackgroundColor))
}
