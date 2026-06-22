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
        VStack(alignment: .leading, spacing: 6) {
            if draftSettings.isUnlimitedContext {
                infoRow(icon: "infinity", color: .orange, text: String(localized: "thread.settings.unlimited_info"))
                infoRow(icon: "bubble.left.and.bubble.right", color: .secondary, text: String(localized: "thread.settings.all_messages_shown"))
            } else {
                let tokenBudget = draftSettings.maxMessagesInContext * 500
                infoRow(icon: "arrow.up.doc", color: .accentColor, text: String(format: String(localized: "thread.settings.token_budget"), formatNumber(tokenBudget)))
            }
        }
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

    func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.locale = Locale(identifier: "ru_RU")
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
