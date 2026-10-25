// ThreadSettingsSheet+Sections.swift
// Chappie
//
// Name, API key, and context depth sections for ThreadSettingsSheet.

import SwiftUI
import ChappieCore

extension ThreadSettingsSheet {

    // MARK: - Name Section

    var nameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("thread.settings.name_section", systemImage: "pencil")

            TextField("thread.settings.name_placeholder", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
        }
    }

    // MARK: - Key Section

    func keySection(provider: AIProvider) -> some View {
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

    var contextSection: some View {
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

    var limitedContextControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("thread.settings.messages_in_context")
                    .font(.callout)
                Spacer()
                Text(verbatim: "\(draftSettings.maxMessagesInContext)")
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

    @ViewBuilder
    var contextInfoBox: some View {
        if draftSettings.isUnlimitedContext {
            VStack(alignment: .leading, spacing: 6) {
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
            }
            .padding(12)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
