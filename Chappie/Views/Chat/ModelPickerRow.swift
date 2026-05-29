// ModelPickerRow.swift
// Chappie
//
// Row displayed above ProjectChipsView showing the active AI provider + model,
// and — on the right — the current account balance from the active provider.
//
// LAYOUT:
//   Left pill  — "Модель:" label + provider·model chip (ultraThinMaterial).
//   Spacer     — pushes the two pills to opposite edges.
//   Right pill — creditcard icon + balance amount (ultraThinMaterial).
//                Visible only when balance is non-nil.
//                Updates live during streaming via onBalanceUpdate in AIOrchestrator.
//
// CHIP STYLE:
//   Only the inner HStack gets ultraThinMaterial pill background.
//   Consistent with ProjectChipsView and the bottom InputMorphView panel.
//
// ORPHANED STATE:
//   If the active provider or model is no longer in the providers list,
//   the row shows a warning style. User can pick a new provider+model inline.
//
// SOFT LOCK (IT-13):
//   When isThinking == true the model picker button is disabled + dimmed (opacity 0.5).
//   Prevents provider/model switching while AI is responding.

import SwiftUI
import ChappieCore

// MARK: - ModelPickerRow

/// Horizontal row with two floating pills: model selector (left) and balance (right).
struct ModelPickerRow: View {

    // MARK: - Input

    let activeProvider: AIProvider?
    let activeModelName: String?
    let providers: [AIProvider]
    let isOrphaned: Bool
    /// Current account balance in RUB — nil until first response received.
    let balance: Double?
    /// When true — picker button is disabled (AI is responding).
    let isThinking: Bool
    let onSelectProvider: (UUID, String) -> Void

    // MARK: - State

    @State private var showPopover: Bool = false

    // MARK: - Body

    var body: some View {
        HStack(spacing: 8) {

            // LEFT PILL: model selector
            modelPill

            Spacer()

            // RIGHT PILL: balance — shown only when a value is available
            if let balance = balance {
                balancePill(balance: balance)
            }
        }
    }

    // MARK: - Left Pill

    private var modelPill: some View {
        HStack(spacing: 6) {
            // "Модель" static label — adaptive color responds correctly to dark/light theme
            Text("Модель")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color(NSColor.controlBackgroundColor))
                )

            // Provider + model selector button — disabled while AI is thinking
            Button {
                showPopover.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isOrphaned ? "exclamationmark.triangle.fill" : "cpu")
                        .font(.system(size: 10))
                        .foregroundStyle(isOrphaned ? Color.orange : Color.accentColor.opacity(0.8))

                    chipLabel

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                // Adaptive background — controlBackgroundColor switches correctly in dark mode
                .background(
                    Capsule()
                        .fill(Color(NSColor.controlBackgroundColor))
                )
                .overlay(
                    Capsule()
                        .stroke(
                            isOrphaned
                                ? Color.orange.opacity(0.3)
                                : Color.accentColor.opacity(0.2),
                            lineWidth: 0.5
                        )
                )
            }
            .buttonStyle(.plain)
            // Keep the button from wrapping — it clips gracefully instead of growing taller
            .fixedSize()
            // Soft lock: disable picker while AI is responding
            .disabled(isThinking)
            .opacity(isThinking ? 0.5 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isThinking)
            .help(isThinking ? "Нельзя менять модель пока Чаппи думает" : "")
            .popover(isPresented: $showPopover, arrowEdge: .top) {
                ModelPickerPopover(
                    providers: providers,
                    activeProviderId: activeProvider?.id,
                    activeModelName: activeModelName,
                    onSelect: { providerId, modelName in
                        onSelectProvider(providerId, modelName)
                        showPopover = false
                    }
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        // Prevent the pill from ever growing taller due to text wrap
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Right Pill (Balance)

    /// Balance pill tied to the active provider.
    /// Green creditcard icon + formatted RUB amount.
    /// Updates in real time as onBalanceUpdate fires during streaming.
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
                // Animate digit changes so the number visibly ticks down during streaming
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        // Adaptive background — controlBackgroundColor switches correctly in dark mode
        .background(Capsule().fill(Color(NSColor.controlBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.easeInOut(duration: 0.3), value: balance)
    }

    // MARK: - Chip Label

    @ViewBuilder
    private var chipLabel: some View {
        if isOrphaned {
            Text("Модель недоступна — выберите другую")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
                .lineLimit(1)
        } else if let provider = activeProvider, let model = activeModelName {
            Text("\(provider.displayName) · \(model)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        } else if let provider = activeProvider {
            Text(provider.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        } else {
            Text("Не выбрана")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - ModelPickerPopover

/// Two-level popover: left = providers, right = models of selected provider.
private struct ModelPickerPopover: View {

    let providers: [AIProvider]
    let activeProviderId: UUID?
    let activeModelName: String?
    let onSelect: (UUID, String) -> Void

    @State private var hoveredProviderId: UUID?

    // Provider shown on the right panel: hovered > active > first
    private var displayedProvider: AIProvider? {
        if let hovered = hoveredProviderId {
            return providers.first { $0.id == hovered }
        }
        if let active = activeProviderId {
            return providers.first { $0.id == active }
        }
        return providers.first
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {

            // Left: provider list
            VStack(alignment: .leading, spacing: 0) {
                Text("Провайдер")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                Divider()

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(providers) { provider in
                            PopoverProviderRow(
                                provider: provider,
                                isActive: provider.id == activeProviderId,
                                isHovered: hoveredProviderId == provider.id
                            )
                            .onHover { hovering in
                                if hovering { hoveredProviderId = provider.id }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 280)
            }
            .frame(width: 180)

            Divider()

            // Right: model list for displayed provider
            VStack(alignment: .leading, spacing: 0) {
                Text("Модель")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                Divider()

                if let provider = displayedProvider {
                    if provider.models.isEmpty {
                        VStack {
                            Spacer()
                            Text("Нет моделей")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: 280)
                    } else {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(provider.models, id: \.self) { model in
                                    PopoverModelRow(
                                        model: model,
                                        isActive: provider.id == activeProviderId && model == activeModelName,
                                        onSelect: { onSelect(provider.id, model) }
                                    )
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(maxHeight: 280)
                    }
                } else {
                    Spacer()
                }
            }
            .frame(width: 220)
        }
        .frame(width: 400)
        .padding(.bottom, 4)
    }
}

// MARK: - PopoverProviderRow

private struct PopoverProviderRow: View {

    let provider: AIProvider
    let isActive: Bool
    let isHovered: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.3))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(provider.displayHost)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 9))
                .foregroundStyle(.secondary.opacity(0.4))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered || isActive
                      ? Color.accentColor.opacity(0.08)
                      : Color.clear)
                .padding(.horizontal, 4)
        )
    }
}

// MARK: - PopoverModelRow

private struct PopoverModelRow: View {

    let model: String
    let isActive: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 16)

                Text(model)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Color.accentColor.opacity(0.08) : Color.clear)
                    .padding(.horizontal, 4)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
