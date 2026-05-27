// ModelPickerRow.swift
// Chappie
//
// IT-10: Row displayed above ProjectChipsView showing the active AI model.
// Tapping opens a popover with provider + model selection (like Xcode Intelligence).
//
// LAYOUT:
// "Модель: <host> <modelName>"  [row with same style as "Проекты:"]
//
// INTERACTION:
// Tap → popover with list of providers
// Each provider → shows selected model name
// Tap provider → immediately switches to it (uses its currently selected model)

import SwiftUI
import ChappieCore

// MARK: - ModelPickerRow

/// Horizontal row showing the active AI model.
/// Tapping opens a provider+model selection popover.
struct ModelPickerRow: View {

    // MARK: - Input

    let activeProvider: AIProvider?
    let providers: [AIProvider]
    let onSelectProvider: (UUID) -> Void

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
                    Image(systemName: "cpu")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor.opacity(0.8))

                    if let provider = activeProvider {
                        Text(provider.displayLabel)
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
                        .fill(Color.accentColor.opacity(0.1))
                )
                .overlay(
                    Capsule()
                        .stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPopover, arrowEdge: .top) {
                ProviderPickerPopover(
                    providers: providers,
                    activeProviderId: activeProvider?.id,
                    onSelect: { id in
                        onSelectProvider(id)
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

// MARK: - ProviderPickerPopover

/// Popover content: list of providers with their selected models.
/// Tapping a provider switches to it immediately.
private struct ProviderPickerPopover: View {

    let providers: [AIProvider]
    let activeProviderId: UUID?
    let onSelect: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("Выбор модели")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            Divider()

            // Provider list
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(providers) { provider in
                        ProviderRow(
                            provider: provider,
                            isActive: provider.id == activeProviderId,
                            onSelect: { onSelect(provider.id) }
                        )
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 320)
        .padding(.bottom, 8)
    }
}

// MARK: - ProviderRow

/// One provider entry in the picker popover.
private struct ProviderRow: View {

    let provider: AIProvider
    let isActive: Bool
    let onSelect: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                // Active indicator
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    // Model name — primary label
                    Text(provider.modelName)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    // Host — secondary label
                    Text(provider.displayHost)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Arrow hint — Xcode Intelligence style
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.accentColor.opacity(0.08) : Color.clear)
                    .padding(.horizontal, 4)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Preview

#Preview {
    ModelPickerRow(
        activeProvider: AIProvider(
            id: UUID(),
            endpoint: "https://api.aitunnel.ru/v1/chat/completions",
            modelName: "claude-sonnet-4.6"
        ),
        providers: [
            AIProvider(
                id: UUID(),
                endpoint: "https://api.aitunnel.ru/v1/chat/completions",
                modelName: "claude-sonnet-4.6"
            ),
            AIProvider(
                id: UUID(),
                endpoint: "https://api.openai.com/v1/chat/completions",
                modelName: "gpt-4o"
            )
        ],
        onSelectProvider: { _ in }
    )
    .frame(width: 600)
    .background(Color(NSColor.windowBackgroundColor))
}
