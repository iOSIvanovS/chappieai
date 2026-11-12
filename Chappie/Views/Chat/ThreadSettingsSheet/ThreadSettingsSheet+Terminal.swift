// ThreadSettingsSheet+Terminal.swift
// Chappie
//
// Terminal switch section and related warning views for ThreadSettingsSheet.

import SwiftUI
import ChappieCore

extension ThreadSettingsSheet {

    // MARK: - Terminal Section

    var terminalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("thread.settings.terminal_section", systemImage: "terminal.fill")

            Toggle("thread.settings.terminal_toggle", isOn: $draftSettings.terminalEnabled)
                .toggleStyle(.switch)

            Text("thread.settings.terminal_toggle_description")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if draftSettings.terminalEnabled {
                autoTerminalWarningView

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                        .padding(.top, 1)
                    Text("thread.settings.terminal_safe_hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                superPowerWarningView
            }
        }
    }

    // MARK: - Warning Views

    var autoTerminalWarningView: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .padding(.top, 1)

            Text("thread.settings.terminal_auto_warning")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    var superPowerWarningView: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 12))
                .foregroundStyle(.purple)
                .padding(.top, 1)

            Text("thread.settings.terminal_superpower_warning")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.purple.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
