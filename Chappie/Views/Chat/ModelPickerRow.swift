// ModelPickerRow.swift
// Chappie
//
// Top floating row: model selector pill (left) + thread settings pill (right).
//
// LAYOUT:
//   Left pill  — "Модель:" label + model chip (ultraThinMaterial).
//   Spacer     — pushes the two pills to opposite edges.
//   Right pill — gear icon + thread name (ultraThinMaterial).
//                Always visible when a thread is active.
//
// CPU-15: STREAMING REFERENCE INSTEAD OF SCALAR PROPS:
//   streaming: StreamingState is passed as a let reference. ModelPickerRow reads
//   streaming.isThinking directly — only this view re-renders on that change.
//   ContentView and topPanel are not invalidated.
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
//   When isThinking == true the model picker button is locked via shakeOnTap().
//   Tapping it triggers a spring-shake animation instead of opacity(0.5) dimming.
//
// TRUNCATION:
//   The model label uses .truncationMode(.middle) so that when the
//   window is narrow the text clips in the middle.
//   Both pills compress gracefully — right pill is fixedSize, left pill gets
//   the remaining space via layoutPriority(1).
//
// MK-07: 3-COLUMN POPOVER (provider / key / model):
//   ModelPickerPopover has a middle "Key" column.
//   When user hovers a provider, its keys are shown immediately.
//   Key auto-selects if provider has exactly one key.
//   onSelectProvider signature: (providerId, keyId, modelName).

import SwiftUI
import ChappieCore

// MARK: - ModelPickerRow

/// Top row: model selector pill (left) + thread settings pill (right).
struct ModelPickerRow: View {

    // MARK: - Input

    let activeProvider: AIProvider?
    let activeModelName: String?
    let activeKeyId: UUID?
    let providers: [AIProvider]
    let isOrphaned: Bool
    let threadName: String?
    /// CPU-15: streaming reference — reads .isThinking directly.
    let streaming: StreamingState
    /// MK-07: keyId added — caller must pass the selected key along with provider+model.
    let onSelectProvider: (UUID, UUID?, String) -> Void
    let onOpenThreadSettings: () -> Void

    // MARK: - State

    @State private var showPopover: Bool = false

    // MARK: - Body

    var body: some View {
        HStack(spacing: 8) {

            // LEFT PILL: model selector — gets all remaining space after right pill is placed
            modelPill
                .layoutPriority(1)

            Spacer(minLength: 8)

            // RIGHT PILL: thread settings gear — always shown when thread is active
            threadSettingsPill
                .fixedSize()
        }
    }

    // MARK: - Left Pill (Model)

    private var modelPill: some View {
        HStack(spacing: 6) {
            Text("Модель")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color(NSColor.controlBackgroundColor)))

            Button {
                showPopover.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isOrphaned ? "exclamationmark.triangle.fill" : "cpu")
                        .font(.system(size: 10))
                        .foregroundStyle(isOrphaned ? Color.orange : Color.accentColor.opacity(0.8))
                        .fixedSize()

                    chipLabel

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color(NSColor.controlBackgroundColor)))
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
            .shakeOnTap(isLocked: streaming.isThinking)
            .help(streaming.isThinking ? "Нельзя менять модель пока Чаппи думает" : "")
            .popover(isPresented: $showPopover, arrowEdge: .top) {
                ModelPickerPopover(
                    providers: providers,
                    activeProviderId: activeProvider?.id,
                    activeKeyId: activeKeyId,
                    activeModelName: activeModelName,
                    onSelect: { providerId, keyId, modelName in
                        onSelectProvider(providerId, keyId, modelName)
                        showPopover = false
                    }
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Right Pill (Thread Settings)

    private var threadSettingsPill: some View {
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
        .shakeOnTap(isLocked: streaming.isThinking)
        .help(streaming.isThinking ? "Нельзя менять настройки пока Чаппи думает" : "Настройки треда")
    }

    // MARK: - Chip Label

    @ViewBuilder
    private var chipLabel: some View {
        if isOrphaned {
            Text("Модель недоступна — выберите другую")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .truncationMode(.middle)
        } else if let model = activeModelName {
            Text(model)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else if activeProvider != nil {
            Text("Выберите модель")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
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

/// Three-column popover: providers → keys of hovered provider → models of hovered provider.
/// Key column auto-selects when provider has exactly one key.
private struct ModelPickerPopover: View {

    let providers: [AIProvider]
    let activeProviderId: UUID?
    let activeKeyId: UUID?
    let activeModelName: String?
    let onSelect: (UUID, UUID?, String) -> Void

    @State private var hoveredProviderId: UUID?
    @State private var selectedKeyId: UUID?

    // Provider shown in key+model columns: hovered > active > first
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

            // Column 1: providers
            providerColumn

            Divider()

            // Column 2: keys for displayed provider
            keyColumn

            Divider()

            // Column 3: models for displayed provider
            modelColumn
        }
        .frame(width: 540)
        .padding(.bottom, 4)
        .onAppear {
            // Restore active key as initial selection
            selectedKeyId = activeKeyId
        }
        .onChange(of: hoveredProviderId) { _, newProviderId in
            guard let provider = providers.first(where: { $0.id == newProviderId }) else { return }
            // Auto-select key when switching providers: single key → select it, multiple → clear
            selectedKeyId = provider.keys.count == 1 ? provider.keys.first?.id : nil
        }
    }

    // MARK: - Provider Column

    private var providerColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader("Провайдер")

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
        .frame(width: 170)
    }

    // MARK: - Key Column

    private var keyColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader("Ключ")

            if let provider = displayedProvider {
                if provider.keys.isEmpty {
                    emptyColumnState(icon: "key.slash", text: "Нет ключей")
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(provider.keys) { key in
                                PopoverKeyRow(
                                    key: key,
                                    isActive: key.id == activeKeyId && provider.id == activeProviderId,
                                    isSelected: key.id == selectedKeyId
                                ) {
                                    selectedKeyId = key.id
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 280)
                }
            } else {
                emptyColumnState(icon: "arrow.left", text: "Выберите провайдера")
            }
        }
        .frame(width: 160)
    }

    // MARK: - Model Column

    private var modelColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader("Модель")

            if let provider = displayedProvider {
                if provider.models.isEmpty {
                    emptyColumnState(icon: "square.stack.3d.up.slash", text: "Нет моделей")
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(provider.models, id: \.self) { model in
                                PopoverModelRow(
                                    model: model,
                                    // Active only when both provider and key match current active
                                    isActive: provider.id == activeProviderId
                                        && model == activeModelName
                                        && selectedKeyId == activeKeyId
                                ) {
                                    onSelect(provider.id, selectedKeyId, model)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 280)
                }
            } else {
                emptyColumnState(icon: "arrow.left", text: "Выберите провайдера")
            }
        }
        .frame(width: 210)
    }

    // MARK: - Helpers

    private func columnHeader(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
            Divider()
        }
    }

    private func emptyColumnState(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(.secondary.opacity(0.3))
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: 280)
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

// MARK: - PopoverKeyRow

private struct PopoverKeyRow: View {

    let key: APIKey
    let isActive: Bool    // currently active in this thread
    let isSelected: Bool  // selected in this popover session
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "checkmark.circle.fill" : (isSelected ? "circle.fill" : "circle"))
                    .font(.system(size: 13))
                    .foregroundStyle(
                        isActive
                            ? Color.accentColor
                            : (isSelected ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.3))
                    )
                    .frame(width: 16)

                Text(key.name)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected || isActive
                          ? Color.accentColor.opacity(0.08)
                          : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
                    .padding(.horizontal, 4)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
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
