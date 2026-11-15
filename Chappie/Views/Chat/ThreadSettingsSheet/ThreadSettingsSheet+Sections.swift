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

            limitedContextControls
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

            // Slider works in steps of 10: 10...100 of them → 10...1000 messages.
            Slider(
                value: Binding(
                    get: { Double(draftSettings.maxMessagesInContext / 10) },
                    set: { draftSettings.maxMessagesInContext = Int($0) * 10 }
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

    var contextInfoBox: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .padding(.top, 1)
            Text("thread.settings.cache_allowance_note")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
