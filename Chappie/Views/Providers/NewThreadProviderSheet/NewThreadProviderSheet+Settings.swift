// NewThreadProviderSheet+Settings.swift
// Chappie
//
// Thread name + context settings sections.

import SwiftUI
import ChappieCore

extension NewThreadProviderSheet {

    // MARK: - Thread Name Section

    var threadNameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("new_thread.name_section", systemImage: "pencil")
                .font(.system(size: 13, weight: .semibold))

            TextField("new_thread.name_placeholder", text: $threadTitle)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
        }
    }

    // MARK: - Context Section

    var contextSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("new_thread.context_section", systemImage: "clock.arrow.circlepath")
                .font(.system(size: 13, weight: .semibold))

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

            // Step 10: map slider 1...100 → actual value × 10
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
                Text("10").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("1 000").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Context Info Box

    var contextInfoBox: some View {
        infoRow(
            icon: "bolt.horizontal.circle",
            color: .secondary,
            text: String(localized: "thread.settings.cache_allowance_note")
        )
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Helpers

    func infoRow(icon: String, color: Color, text: String) -> some View {
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
}
