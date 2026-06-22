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

    func balancePill(balance: Double) -> some View {
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
}
