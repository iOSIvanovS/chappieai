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
//
//   LAYOUT STRATEGY — explicit frame(maxWidth):
//   The outer HStack is measured via a ZStack with a full-width Color.clear
//   probe (background GeometryReader). The right pill declares .fixedSize()
//   and its width is captured by another GeometryReader.
//   Left pill receives frame(maxWidth: totalWidth - rightPillWidth - spacing)
//   so FlowLayout always gets a finite proposal and wraps correctly.
//
//   WHY NOT layoutPriority:
//     layoutPriority(1) does NOT cap the child's desired width — it only
//     controls allocation order. FlowLayout.sizeThatFits with an unconstrained
//     proposal returns single-row intrinsic width; SwiftUI uses that as the
//     "desired" size, so the pill still fills all available space.
//
//   WHY NOT ChipsRowLayout (custom Layout):
//     sizeThatFits(.unspecified) passes width=nil → FlowLayout sees ∞ → same
//     single-row intrinsic result → same stretching.
//
// THREAD SETTINGS CHIP (IT-12):
//   Right-side pill shows gear icon + thread name.
//   Tap → onOpenThreadSettings() → ContentView shows ThreadSettingsSheet.
//
// IT-09: Tap on chip opens ProjectSettingsSheet.
// IT-13: Soft lock — shake animation instead of opacity dimming.

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

    // MARK: - Callbacks

    let onAddProject: (URL) -> Void
    let onRemoveProject: (UUID) -> Void
    let onOpenSettings: (UUID) -> Void
    let onOpenThreadSettings: () -> Void

    // MARK: - Measurement state

    @State private var hoveredProjectId: UUID? = nil
    /// Full available width of the row — measured via background probe.
    @State private var totalWidth: CGFloat = 0
    /// Intrinsic width of the right (gear) pill — measured via background probe.
    @State private var rightPillWidth: CGFloat = 0

    private let pillSpacing: CGFloat = 8

    /// Max width for the left pill so FlowLayout receives a finite proposal.
    private var leftMaxWidth: CGFloat {
        guard totalWidth > 0, rightPillWidth > 0 else { return .infinity }
        return max(60, totalWidth - rightPillWidth - pillSpacing)
    }

    // MARK: - Body

    var body: some View {
        // ZStack: bottom layer is an invisible full-width probe that measures totalWidth.
        // Top layer is the real content — it does NOT affect the probe's sizing.
        ZStack(alignment: .topLeading) {

            // Invisible width probe — stretches to fill available width
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: 1)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { totalWidth = geo.size.width }
                            .onChange(of: geo.size.width) { _, w in totalWidth = w }
                    }
                )

            // Real content row
            HStack(alignment: .top, spacing: pillSpacing) {

                // LEFT pill: projects + FlowLayout wrapping
                // frame(maxWidth:) gives FlowLayout a finite proposal → wraps correctly.
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
                .frame(maxWidth: leftMaxWidth, alignment: .leading)

                Spacer(minLength: 0)

                // RIGHT pill: gear + thread name — intrinsic size only
                threadSettingsButton
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

    // MARK: - "Проекты" label

    private var projectsLabel: some View {
        Text("Проекты")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color(NSColor.controlBackgroundColor)))
    }

    // MARK: - Thread settings button (right pill)

    private var threadSettingsButton: some View {
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
        .fixedSize()
        .shakeOnTap(isLocked: isThinking)
    }

    // MARK: - Project chip

    private func projectChip(for project: ProjectMetadata) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.accentColor.opacity(0.8))

            Text(project.displayName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary)

            roleIndicator(for: project.settings.agentRole)

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
        .background(Capsule().fill(Color(NSColor.controlBackgroundColor)))
        .overlay(Capsule().stroke(Color.accentColor.opacity(0.2), lineWidth: 0.5))
        .onHover { isHovered in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredProjectId = isHovered ? project.id : nil
            }
        }
        .onTapGesture {
            if !isThinking { onOpenSettings(project.id) }
        }
        .shakeOnTap(isLocked: isThinking)
        .help("Проект: \(project.displayName) (\(project.settings.agentRole.displayName))\nТап — настройки\(isThinking ? "" : ", × — убрать из треда")")
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
                        .overlay(Capsule().stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
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
            ProjectMetadata(id: UUID(), displayName: "Chappie",
                            settings: ProjectSettings(agentRole: .executor, isProgrammingProject: true)),
            ProjectMetadata(id: UUID(), displayName: "MyApp",
                            settings: ProjectSettings(agentRole: .advisor)),
            ProjectMetadata(id: UUID(), displayName: "Backend API",
                            settings: ProjectSettings(agentRole: .executor, isProgrammingProject: true))
        ],
        threadName: "Разработка Chappie",
        isThinking: false,
        onAddProject: { _ in },
        onRemoveProject: { _ in },
        onOpenSettings: { _ in },
        onOpenThreadSettings: {}
    )
    .padding()
    .frame(width: 300)
    .background(Color(NSColor.windowBackgroundColor))
}

#Preview("Заблокировано") {
    ProjectChipsView(
        projects: [
            ProjectMetadata(id: UUID(), displayName: "Chappie",
                            settings: ProjectSettings(agentRole: .executor, isProgrammingProject: true))
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
