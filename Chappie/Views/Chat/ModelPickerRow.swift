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
//
// ICONS: provider icon shown in chip and in each submenu entry.

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
            Text("toolbar.model_label")
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
                    Menu {
                        ForEach(provider.models) { model in
                            Button {
                                handleSelection(provider: provider, model: model)
                            } label: {
                                let isActive = provider.id == activeProvider?.id
                                    && model.id == activeModelName
                                Label(
                                    model.displayName,
                                    systemImage: isActive ? "checkmark" : ""
                                )
                            }
                        }

                        if provider.models.isEmpty {
                            Text("new_thread.no_models")
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        // Provider name in submenu — no icon support in macOS Menu labels
                        Text(provider.displayName)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    // Show active provider icon if selected, otherwise generic cpu
                    if let provider = activeProvider, !isOrphaned {
                        Image(systemName: provider.iconName)
                            .font(.system(size: 10))
                            .foregroundStyle(provider.resolvedIconColor)
                            .fixedSize()
                    } else {
                        Image(systemName: isOrphaned ? "exclamationmark.triangle.fill" : "cpu")
                            .font(.system(size: 10))
                            .foregroundStyle(isOrphaned ? Color.orange : Color.accentColor.opacity(0.8))
                            .fixedSize()
                    }

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
            .shakeOnTap(isLocked: streaming.isThinking)
            .help(streaming.isThinking ? String(localized: "toolbar.model_locked") : "")
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
        .help(streaming.isThinking ? String(localized: "toolbar.settings_locked") : String(localized: "thread.row.settings"))
    }

    // MARK: - Chip Label

    @ViewBuilder
    private var chipLabel: some View {
        if isOrphaned {
            Text("thread.model_unavailable")
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
            Text("new_thread.select_model_hint")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
                .lineLimit(1)
        } else {
            Text("thread.no_model_selected")
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
