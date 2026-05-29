// ProjectChipsView.swift
// Chappie
//
// Floating pill row showing project chips for the current thread.
// Chips wrap to new lines when the window is narrowed (FlowLayout).
//
// CHIP STYLE:
//   Only the inner content gets ultraThinMaterial pill background.
//   Consistent with ModelPickerRow and the bottom InputMorphView panel.
//
// FLOW WRAPPING (IT-14):
//   Project chips use FlowLayout — a custom Layout that packs items
//   left-to-right and wraps to the next line when width is exceeded.
//   This prevents the pill from overflowing the window on narrow sizes.
//   The "Проекты" label + chips + add button all live inside FlowLayout,
//   so the label stays on the first line and chips flow naturally after it.
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
//   - "+" (add project) button is locked — shake animation on tap instead of dimming.
//   - "×" (remove project) button is hidden entirely.
//   - Thread settings gear is locked — shake animation on tap instead of dimming.
//   - Project chips are locked — shake animation on tap instead of dimming.
//   All elements stay fully visible (no opacity reduction).
//   Uses shakeOnTap (allowsHitTesting) instead of .disabled() to avoid
//   SwiftUI's automatic opacity(0.5) side effect.

import SwiftUI
import ChappieCore

// MARK: - ProjectChipsView

/// Floating pill showing project chips for the current thread.
/// Chips wrap to new lines on narrow windows via FlowLayout.
struct ProjectChipsView: View {

    // MARK: - Input

    let projects: [ProjectMetadata]

    /// Active thread name — used as label in the gear chip.
    let threadName: String?

    /// When true — add/remove project and thread settings gear are locked (IT-13).
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
        HStack(alignment: .top, spacing: 8) {

            // Left: projects pill — wraps content via FlowLayout
            FlowLayout(spacing: 6) {

                // "Проекты" static label
                Text("Проекты")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color(NSColor.controlBackgroundColor))
                    )

                // Project chips — one per project
                ForEach(projects) { project in
                    projectChip(for: project)
                }

                // "+" add button
                addButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Spacer(minLength: 0)

            // Right: gear chip — opens thread settings.
            // Locked while AI is thinking — shake animation on tap (IT-13).
            Button(action: onOpenThreadSettings) {
                HStack(spacing: 5) {
                    Image(systemName: "gear")
                        .font(.system(size: 10, weight: .medium))

                    if let threadName {
                        Text(threadName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color(NSColor.controlBackgroundColor)))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            // Soft lock: shake on tap when locked (IT-13)
            .shakeOnTap(isLocked: isThinking)
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
                .fill(Color(NSColor.controlBackgroundColor))
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
            if !isThinking {
                onOpenSettings(project.id)
            }
        }
        // Soft lock: shake on tap when locked (IT-13)
        .shakeOnTap(isLocked: isThinking)
        .help("Проект: \(project.displayName) (\(project.settings.agentRole.displayName))\nТап — настройки\(isThinking ? "" : ", × — убрать из треда")")
    }

    /// Small agent role indicator next to the project name.
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
                        .fill(Color(NSColor.controlBackgroundColor))
                        .overlay(
                            Capsule()
                                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .shakeOnTap(isLocked: isThinking)
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
            ),
            ProjectMetadata(
                id: UUID(),
                displayName: "Backend API",
                settings: ProjectSettings(agentRole: .executor, isProgrammingProject: true)
            )
        ],
        threadName: "Разработка Chappie",
        isThinking: false,
        onAddProject: { _ in },
        onRemoveProject: { _ in },
        onOpenSettings: { _ in },
        onOpenThreadSettings: {}
    )
    .padding()
    .frame(width: 300) // narrow window to test wrapping
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
