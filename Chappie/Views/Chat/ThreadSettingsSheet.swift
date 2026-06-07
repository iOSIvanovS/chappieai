// ThreadSettingsSheet.swift
// Chappie
//
// Sheet for editing per-thread settings.
// Opened from two places: gear icon in ThreadRowView (sidebar) and gear chip in ProjectChipsView.
//
// ARCHITECTURE (DUMB COMPONENT PRINCIPLE):
// Receives ThreadMetadata + available providers, returns via onSave.
// No direct dependency on ViewModel or SwiftData.
//
// SETTINGS:
// - Thread name (inline rename)
// - API key selection (hidden for providers with requiresApiKey=false, e.g. Ollama)
// - Context depth: slider 10...1000, step 10, default 30
// - Unlimited context toggle
//
// NOTE: Provider + model selection happens ONLY via the "Model" chip in the chat toolbar.
// Adding/editing/deleting providers happens ONLY in the provider directory (SettingsView).

import SwiftUI
import ChappieCore

// MARK: - ThreadSettingsSheet

struct ThreadSettingsSheet: View {

    // MARK: - Input

    let thread: ThreadMetadata
    let providers: [AIProvider]
    let onSave: (String, ThreadSettings, UUID?, UUID?, String?) -> Void
    let onDismiss: () -> Void

    // MARK: - Local draft state

    @State private var draftTitle: String
    @State private var draftSettings: ThreadSettings
    @State private var draftKeyId: UUID?

    // MARK: - Active provider (resolved from draftSettings)

    private var activeProvider: AIProvider? {
        guard let id = draftSettings.activeProviderId else { return nil }
        return providers.first { $0.id == id }
    }

    // MARK: - Init

    init(
        thread: ThreadMetadata,
        providers: [AIProvider],
        onSave: @escaping (String, ThreadSettings, UUID?, UUID?, String?) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.thread = thread
        self.providers = providers
        self.onSave = onSave
        self.onDismiss = onDismiss
        self._draftTitle = State(initialValue: thread.title)
        self._draftSettings = State(initialValue: thread.settings)
        self._draftKeyId = State(initialValue: thread.settings.activeKeyId)

        print("[ThreadSettingsSheet] init: providerId=\(thread.settings.activeProviderId?.uuidString ?? "nil") keyId=\(thread.settings.activeKeyId?.uuidString ?? "nil") maxMsgs=\(thread.settings.maxMessagesInContext)")
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    nameSection
                    Divider().padding(.vertical, 2)
                    if let provider = activeProvider, provider.requiresApiKey {
                        keySection(provider: provider)
                        Divider().padding(.vertical, 2)
                    }
                    contextSection
                }
                .padding(20)
            }

            Divider()
            footerView
        }
        .frame(width: 480)
        .frame(minHeight: 320)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 10) {
            Image(systemName: "gear")
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("thread.settings.title")
                    .font(.headline)
                Text(draftTitle.isEmpty ? String(localized: "thread.settings.untitled") : draftTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    // MARK: - Name Section

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("thread.settings.name_section", systemImage: "pencil")

            TextField("thread.settings.name_placeholder", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
        }
    }

    // MARK: - Key Section

    private func keySection(provider: AIProvider) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("thread.settings.api_key", systemImage: "key")

            if provider.keys.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "key.slash")
                        .foregroundStyle(.secondary)
                    Text("thread.settings.no_keys")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 4) {
                    ForEach(provider.keys) { key in
                        KeySelectRow(
                            key: key,
                            isSelected: draftKeyId == key.id,
                            onSelect: { draftKeyId = key.id }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Context Depth Section

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("thread.settings.context_depth", systemImage: "clock.arrow.circlepath")

            Toggle(isOn: $draftSettings.isUnlimitedContext) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("thread.settings.unlimited")
                        .font(.callout)
                    Text("thread.settings.unlimited_hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            if !draftSettings.isUnlimitedContext {
                limitedContextControls
            }

            contextInfoBox
        }
    }

    // MARK: - Limited Context Controls

    private var limitedContextControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("thread.settings.messages_in_context")
                    .font(.callout)
                Spacer()
                Text("\(draftSettings.maxMessagesInContext)")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .frame(minWidth: 44, alignment: .trailing)
            }

            // Step 10: map slider 1...100 → actual value × 10
            Slider(
                value: Binding(
                    get: { Double(draftSettings.maxMessagesInContext / 10) },
                    set: {
                        let newVal = Int($0) * 10
                        print("[ThreadSettingsSheet] Slider set: raw=\($0) → maxMsgs=\(newVal)")
                        draftSettings.maxMessagesInContext = newVal
                    }
                ),
                in: 1...100,
                step: 1
            )
            .accentColor(Color.accentColor)

            HStack {
                Text("10")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("1 000")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Context Info Box

    private var contextInfoBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            if draftSettings.isUnlimitedContext {
                infoRow(
                    icon: "infinity",
                    color: .orange,
                    text: String(localized: "thread.settings.unlimited_info")
                )
                infoRow(
                    icon: "bubble.left.and.bubble.right",
                    color: .secondary,
                    text: String(localized: "thread.settings.all_messages_shown")
                )
            } else {
                let tokenBudget = draftSettings.maxMessagesInContext * 500
                infoRow(
                    icon: "arrow.up.doc",
                    color: .accentColor,
                    text: String(format: String(localized: "thread.settings.token_budget"), formatNumber(tokenBudget))
                )
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Button("thread.settings.cancel") {
                onDismiss()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button("thread.settings.save") {
                let trimmedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalTitle = trimmedTitle.isEmpty ? thread.title : trimmedTitle
                var updatedSettings = draftSettings

                // For keyless providers (e.g. Ollama) — preserve the original keyId unchanged.
                // Only pass draftKeyId when the provider actually requires a key.
                let effectiveKeyId: UUID?
                if let provider = activeProvider, provider.requiresApiKey {
                    effectiveKeyId = draftKeyId
                } else {
                    effectiveKeyId = thread.settings.activeKeyId
                }

                updatedSettings.activeKeyId = effectiveKeyId

                print("[ThreadSettingsSheet] onSave: title='\(finalTitle)' maxMsgs=\(updatedSettings.maxMessagesInContext) keyId=\(effectiveKeyId?.uuidString ?? "nil") providerId=\(updatedSettings.activeProviderId?.uuidString ?? "nil") activeProvider=\(activeProvider?.displayName ?? "nil")")

                onSave(finalTitle, updatedSettings, nil, effectiveKeyId, nil)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(16)
    }

    // MARK: - Helpers

    private func sectionLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
    }

    private func infoRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 14)
                .padding(.top, 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func infoRow(icon: String, color: AnyShapeStyle, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 14)
                .padding(.top, 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.locale = Locale(identifier: "ru_RU")
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

// MARK: - KeySelectRow

private struct KeySelectRow: View {

    let key: APIKey
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.3))

                Text(key.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.1)
                          : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Preview

#Preview("Default settings") {
    ThreadSettingsSheet(
        thread: ThreadMetadata(
            id: UUID(),
            title: "Chappie Development",
            settings: ThreadSettings(),
            projectIds: [],
            createdAt: Date(),
            updatedAt: Date()
        ),
        providers: [],
        onSave: { title, settings, _, _, _ in
            print("Save: \(title)")
        },
        onDismiss: {}
    )
}
