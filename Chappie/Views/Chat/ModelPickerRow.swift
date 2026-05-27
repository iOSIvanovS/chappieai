// ModelPickerRow.swift
// Chappie
//
// Row displayed above ProjectChipsView showing the active AI provider + model.
// Tapping opens a popover with two-level provider → model selection.
//
// ORPHANED STATE:
// If the active provider or model is no longer in the providers list,
// the row shows a warning style. User can pick a new provider+model inline.

import SwiftUI
import ChappieCore

// MARK: - ModelPickerRow

/// Horizontal row showing the active AI provider + model.
/// Tapping opens a two-level provider+model selection popover.
struct ModelPickerRow: View {

    // MARK: - Input

    let activeProvider: AIProvider?
    let activeModelName: String?
    let providers: [AIProvider]
    let isOrphaned: Bool
    let onSelectProvider: (UUID, String) -> Void

    // MARK: - State

    @State private var showPopover: Bool = false

    // MARK: - Body

    var body: some View {
        HStack(spacing: 6) {
            Text("Модель:")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Button {
                showPopover.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isOrphaned ? "exclamationmark.triangle.fill" : "cpu")
                        .font(.system(size: 10))
                        .foregroundStyle(isOrphaned ? Color.orange : Color.accentColor.opacity(0.8))

                    if isOrphaned {
                        Text("Модель недоступна — выберите другую")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.orange)
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
                    }

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isOrphaned
                              ? Color.orange.opacity(0.1)
                              : Color.accentColor.opacity(0.1))
                )
                .overlay(
                    Capsule()
                        .stroke(
                            isOrphaned
                                ? Color.orange.opacity(0.4)
                                : Color.accentColor.opacity(0.25),
                            lineWidth: 0.5
                        )
                )
            }
            .buttonStyle(.plain)
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

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Color.primary.opacity(0.06)),
            alignment: .bottom
        )
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

    // The provider currently shown on the right panel
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
            .frame(width: 200)
        }
        .frame(width: 380)
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

                // weight before design — correct argument order for .system()
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
