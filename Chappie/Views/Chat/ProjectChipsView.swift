// ProjectChipsView.swift
// Chappie
//
// Floating pill row showing project chips for the current thread.
// Chips wrap to new lines when the window is narrowed (FlowLayout).
//
// LAYOUT STRATEGY (FINAL):
//   ZStack approach:
//     - Bottom layer: leftPill with frame(maxWidth: .infinity) — fills all available width.
//       FlowLayout receives a finite proposal and wraps chips correctly.
//     - Top layer (trailing): balancePill with fixedSize() — floats over the right edge.
//                              Shown only when balance is non-nil.
//
//   WHY NOT HStack + Spacer:
//     HStack first asks leftPill for its intrinsic size (proposal.width = nil).
//     FlowLayout returns one long row (= intrinsic). HStack then offers exactly
//     that width — leftPill never gets a narrower proposal → no wrapping ever occurs.
//
//   WHY ZStack WORKS:
//     ZStack offers ALL subviews the SAME proposal (the full available width).
//     leftPill gets frame(maxWidth: .infinity) → FlowLayout receives the full width
//     as its proposal → wraps correctly when chips don't fit.
//     balancePill has fixedSize() → takes only its intrinsic width,
//     aligned to the trailing edge via ZStack(alignment: .topTrailing).
//
// IT-09: Tap on chip opens ProjectSettingsSheet.
// IT-13: Soft lock — shake animation instead of opacity dimming.
//
// FS READINESS:
//   isFileSystemReady=false → project chips show a small spinner instead of folder icon,
//   addButton is disabled. Cleared once syncFileSystemForActiveThread() completes.
//
// B-05 UNAVAILABILITY:
//   project.isUnavailable=true → chip shows orange warning icon + orange border.
//   Tooltip explains the folder is missing. User must restore the folder or remove the project.
//   On next app start / thread switch, if folder is back — chip returns to normal.
//
// CPU-15: BALANCE ISOLATION:
//   balance is passed as Double? from StreamingState.currentBalance in ContentView.
//   Balance pill is hidden when nil — provider doesn't support balance or hasn't returned one.
//   Balance updates do NOT invalidate ContentView — only ProjectChipsView re-renders.
//
// UX: Remove button is always visible (not hover-triggered) to prevent chip width jitter.

import SwiftUI
import ChappieCore

// MARK: - ProjectChipsView

/// Floating pill showing project chips for the current thread.
/// Chips wrap to new lines on narrow windows via FlowLayout.
struct ProjectChipsView: View {

    // MARK: - Input

    let projects: [ProjectMetadata]
    let threadName: String?
    let isThinking: Bool
    let isFileSystemReady: Bool
    /// Current provider balance — nil when provider doesn't return balance.
    let balance: Double?

    // MARK: - Callbacks

    let onAddProject: (URL) -> Void
    let onRemoveProject: (UUID) -> Void
    let onOpenSettings: (UUID) -> Void

    // MARK: - State

    /// Width of the right pill — measured via background GeometryReader.
    @State private var rightPillWidth: CGFloat = 0

    // MARK: - Body

    var body: some View {
        // ZStack: leftPill fills full width, balancePill floats top-trailing.
        // Both receive the same width proposal from ZStack = full available width.
        ZStack(alignment: .topTrailing) {

            // LEFT PILL: fills full width, FlowLayout wraps chips.
            // Padding on the right side reserves space so chips don't hide under balancePill.
            leftPill
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, balance != nil ? rightPillWidth + 8 : 0)

            // RIGHT PILL: balance — shown only when a value is available.
            if let balance {
                balancePill(balance: balance)
                    .fixedSize()
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { rightPillWidth = geo.size.width }
                                .onChange(of: geo.size.width) { _, w in rightPillWidth = w }
                        }
                    )
            }
        }
    }

    // MARK: - Left Pill

    private var leftPill: some View {
        FlowLayout(spacing: 6) {
            projectsLabel
            ForEach(projects) { project in
                projectChip(for: project)
            }
            addButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - "Projects" label

    private var projectsLabel: some View {
        Text("project.chips.label")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color(NSColor.controlBackgroundColor)))
    }

    // MARK: - Right Pill (Balance)

    private func balancePill(balance: Double) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "creditcard.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green)

            Text(String(format: "%.2f ₽", balance))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color(NSColor.controlBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.easeInOut(duration: 0.3), value: balance)
    }

    // MARK: - Project chip

    private func projectChip(for project: ProjectMetadata) -> some View {
        // Unavailable = folder missing/trashed. Orange icon, orange border.
        // Loading = FS sync in progress. Spinner, no interaction.
        // Normal = folder healthy. Blue icon, full interaction.
        let chipColor: Color = project.isUnavailable ? .orange : Color.accentColor
        let borderOpacity: Double = project.isUnavailable ? 0.6 : (isFileSystemReady ? 0.2 : 0.08)
        let isInteractive = !isThinking && isFileSystemReady && !project.isUnavailable
        // Remove button is visible when not blocked by thinking/loading.
        // Always shown for unavailable projects so user can clean up broken entries.
        let showRemove = !isThinking && isFileSystemReady

        return HStack(spacing: 4) {
            if project.isUnavailable {
                // Orange warning icon — folder is missing or in Trash.
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            } else if !isFileSystemReady {
                // Spinner while FS is syncing.
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.55)
                    .frame(width: 10, height: 10)
            } else {
                // Normal healthy folder icon.
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(chipColor.opacity(0.8))
            }

            Text(project.displayName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(project.isUnavailable ? .orange : .primary)

            if !project.isUnavailable {
                roleIndicator(for: project.settings.agentRole)
            }

            // Remove button is always visible — no hover needed.
            // Prevents chip width jitter caused by the button appearing/disappearing on hover.
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
        .background(Capsule().fill(
            project.isUnavailable
                ? Color.orange.opacity(0.08)
                : Color(NSColor.controlBackgroundColor)
        ))
        .overlay(Capsule().stroke(chipColor.opacity(borderOpacity), lineWidth: project.isUnavailable ? 1.0 : 0.5))
        .onTapGesture {
            if isInteractive { onOpenSettings(project.id) }
        }
        .shakeOnTap(isLocked: isThinking)
        .help(helpText(for: project))
    }

    // MARK: - Chip help text

    private func helpText(for project: ProjectMetadata) -> String {
        if project.isUnavailable {
            return String(format: String(localized: "project.chips.unavailable_hint"), project.displayName)
        }
        if !isFileSystemReady {
            return String(localized: "project.chips.add_locked_loading")
        }
        let removeHint = isThinking ? "" : String(localized: "project.chips.chip_hint_remove")
        return String(format: String(localized: "project.chips.chip_hint"), project.displayName, project.settings.agentRole.displayName, removeHint)
    }

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

    // MARK: - Private helpers

    private func openFolderPicker() {
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

// MARK: - Preview

#Preview("With projects") {
    ProjectChipsView(
        projects: [
            ProjectMetadata(id: UUID(), displayName: "Chappie",
                            settings: ProjectSettings(agentRole: .executor, isProgrammingProject: true)),
            ProjectMetadata(id: UUID(), displayName: "MyApp",
                            settings: ProjectSettings(agentRole: .advisor)),
            ProjectMetadata(id: UUID(), displayName: "Backend API",
                            settings: ProjectSettings(agentRole: .executor, isProgrammingProject: true))
        ],
        threadName: "Chappie Development",
        isThinking: false,
        isFileSystemReady: true,
        balance: 2120.09,
        onAddProject: { _ in },
        onRemoveProject: { _ in },
        onOpenSettings: { _ in }
    )
    .padding()
    .frame(width: 300)
    .background(Color(NSColor.windowBackgroundColor))
}

#Preview("No balance") {
    ProjectChipsView(
        projects: [
            ProjectMetadata(id: UUID(), displayName: "Chappie",
                            settings: ProjectSettings(agentRole: .executor, isProgrammingProject: true))
        ],
        threadName: "Chappie Development",
        isThinking: false,
        isFileSystemReady: true,
        balance: nil,
        onAddProject: { _ in },
        onRemoveProject: { _ in },
        onOpenSettings: { _ in }
    )
    .padding()
    .frame(width: 300)
    .background(Color(NSColor.windowBackgroundColor))
}

#Preview("Unavailable project") {
    ProjectChipsView(
        projects: [
            ProjectMetadata(id: UUID(), displayName: "Chappie",
                            settings: ProjectSettings(agentRole: .executor, isProgrammingProject: true),
                            isUnavailable: false),
            ProjectMetadata(id: UUID(), displayName: "test",
                            settings: ProjectSettings(agentRole: .executor, isProgrammingProject: true),
                            isUnavailable: true)
        ],
        threadName: "Test",
        isThinking: false,
        isFileSystemReady: true,
        balance: nil,
        onAddProject: { _ in },
        onRemoveProject: { _ in },
        onOpenSettings: { _ in }
    )
    .padding()
    .frame(width: 350)
    .background(Color(NSColor.windowBackgroundColor))
}

#Preview("Locked") {
    ProjectChipsView(
        projects: [
            ProjectMetadata(id: UUID(), displayName: "Chappie",
                            settings: ProjectSettings(agentRole: .executor, isProgrammingProject: true))
        ],
        threadName: "Chappie Development",
        isThinking: true,
        isFileSystemReady: true,
        balance: 82.69,
        onAddProject: { _ in },
        onRemoveProject: { _ in },
        onOpenSettings: { _ in }
    )
    .padding()
    .background(Color(NSColor.windowBackgroundColor))
}
