// ModelPickerRow.swift
// Chappie
//
// Top floating row: model selector pill (left) + thread settings pill (right).
//
// MK-08: Native macOS Menu replaces custom 2-column popover.
//        Providers appear as submenus — each with their model list.
//        Active model gets a checkmark. No hover/click race conditions.
//        Key auto-resolution: same provider → keep current key.
//        New provider → last used key (from thread settings) or first key.
//        Keyless providers (requiresApiKey=false) → nil key always.

import SwiftUI
import ChappieCore

// MARK: - ModelPickerRow

struct ModelPickerRow: View {

    let activeProvider: AIProvider?
    let activeModelName: String?
    let activeKeyId: UUID?
    let providers: [AIProvider]
    let isOrphaned: Bool
    let threadName: String?
    let streaming: StreamingState
    let onSelectProvider: (UUID, UUID?, String) -> Void
    let onOpenThreadSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            modelPill
                .layoutPriority(1)

            Spacer(minLength: 8)

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

            // Native macOS menu — label styled to match other chips
            Menu {
                ForEach(providers) { provider in
                    Menu(provider.displayName) {
                        ForEach(provider.models) { model in
                            let isActive = provider.id == activeProvider?.id
                                && model.id == activeModelName
                            Button {
                                handleSelection(provider: provider, model: model)
                            } label: {
                                if isActive {
                                    Label(model.displayName, systemImage: "checkmark")
                                } else {
                                    Text(model.displayName)
                                }
                            }
                        }

                        if provider.models.isEmpty {
                            Text("Нет моделей")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } label: {
                // Plain label — no background here, background is on the pill wrapper below
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
            }
            .menuStyle(.borderlessButton)
            // White pill background — same as other chips
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
            .fixedSize()
            //.disabled(streaming.isThinking)
            .shakeOnTap(isLocked: streaming.isThinking)
            .help(streaming.isThinking ? "Нельзя менять модель пока Чаппи думает" : "")
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

    // MARK: - Selection Handler

    private func handleSelection(provider: AIProvider, model: AIModel) {
        let resolvedKeyId: UUID?
        if !provider.requiresApiKey {
            // Local provider (e.g. Ollama) — never needs a key
            resolvedKeyId = nil
        } else if provider.id == activeProvider?.id {
            // Same provider — keep current key
            resolvedKeyId = activeKeyId
        } else {
            // New provider — use first available key
            resolvedKeyId = provider.keys.first?.id
        }
        onSelectProvider(provider.id, resolvedKeyId, model.id)
    }
}
