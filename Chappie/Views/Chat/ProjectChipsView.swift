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
//   Right-side pill shows gear icon only (no thread name — saves space).
//   Tap → onOpenThreadSettings() → ContentView shows ThreadSettingsSheet.
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
//
// SOFT LOCK (IT-13):
//   When isThinking == true:
//   - "+" (add project) button is disabled + dimmed.
//   - "×" (remove project) button is hidden entirely.
//   - Thread settings gear is disabled + dimmed.
//   This prevents project attach/detach and thread settings changes while AI responds.

import SwiftUI
import ChappieCore

// MARK: - ProjectChipsView

/// Horizontal row of project chips for the current thread.
///
/// Shows projects bound to the thread.
/// "+" button adds a new project via NSOpenPanel.
/// "×" button on each chip removes the project from the thread.
/// Tap on chip opens project settings (IT-09).
/// Gear pill on the right opens thread settings (IT-12).
struct ProjectChipsView: View {

    // MARK: - Input

    let projects: [ProjectMetadata]

    /// Active thread name — used in tooltip for the gear chip.
    let threadName: String?

    /// When true — add/remove project and thread settings gear are disabled (IT-13).
    let isThinking: Bool

    // MARK: - Callbacks

    /// Called when the user taps "+" and selects a folder.
    let onAddProject: (URL) -> Void

    /// Called when the user taps "×" on a chip.
    let onRemoveProject: (UUID) -> Void

    /// Called when the user taps a chip to open project settings (IT-09).
    let onOpenSettings: (UUID) -> Void

    /// Called when the user taps the thread settings gear to open thread settings.
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

            // Right: gear chip — opens thread settings.
            // Disabled while AI is thinking (IT-13).
            Button(action: onOpenThreadSettings) {
                Image(systemName: "gear")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isThinking ? Color.secondary.opacity(0.4) : Color.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .disabled(isThinking)
            .opacity(isThinking ? 0.5 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isThinking)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .help(isThinking
                  ? "Нельзя открыть настройки треда пока Чаппи думает"
                  : (threadName.map { "Настройки треда «\($0)»" } ?? "Настройки треда"))
        }
    }

    // MARK: - Project chip

    /// Individual chip for one project.
    ///
    /// HOVER BEHAVIOUR:
    /// On hover — the "×" button appears to the right of the name (only when NOT thinking).
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

            // "×" remove button — hidden while AI is thinking (IT-13)
            if hoveredProjectId == project.id && !isThinking {
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
        .help("Проект: \(project.displayName) (\(project.settings.agentRole.displayName))\nТап — настройки\(isThinking ? "" : ", × — убрать из треда")")
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

    /// "+" button to attach a new project folder to the thread.
    /// Disabled while AI is thinking (IT-13).
    private var addButton: some View {
        Button {
            openFolderPicker()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 5)
                .foregroundStyle(isThinking ? Color.secondary : Color.accentColor)
                .background(
                    Capsule()
                        .fill(.white)
                        .overlay(
                            Capsule()
                                .stroke(
                                    isThinking
                                        ? Color.secondary.opacity(0.2)
                                        : Color.accentColor.opacity(0.35),
                                    lineWidth: 1
                                )
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(isThinking)
        .opacity(isThinking ? 0.5 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isThinking)
        .help(isThinking ? "Нельзя добавить проект пока Чаппи думает" : "Добавить папку проекта к этому треду")
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
        isThinking: false,
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

#Preview("Заблокировано (isThinking)") {
    ProjectChipsView(
        projects: [
            ProjectMetadata(
                id: UUID(),
                displayName: "Chappie",
                settings: ProjectSettings(agentRole: .executor, isProgrammingProject: true)
            )
        ],
        threadName: "Разработка Chappie",
        isThinking: true,
        onAddProject: { _ in },
        onRemoveProject: { _ in },
        onOpenSettings: { _ in },
        onOpenThreadSettings: {}
    )
    .padding()
    .background(Color(NSColor.windowBackgroundColor))
}

#Preview("Пустой список") {
    ProjectChipsView(
        projects: [],
        threadName: "Новый тред",
        isThinking: false,
        onAddProject: { _ in },
        onRemoveProject: { _ in },
        onOpenSettings: { _ in },
        onOpenThreadSettings: {}
    )
    .padding()
    .background(Color(NSColor.windowBackgroundColor))
}
