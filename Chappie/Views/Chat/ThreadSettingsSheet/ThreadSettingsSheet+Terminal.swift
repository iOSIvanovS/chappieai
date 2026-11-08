// ThreadSettingsSheet+Terminal.swift
// Chappie
//
// Terminal access section and related warning views for ThreadSettingsSheet.

import SwiftUI
import ChappieCore

extension ThreadSettingsSheet {

    // MARK: - Terminal Section

    var terminalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("thread.settings.terminal_section", systemImage: "terminal.fill")

            Picker("thread.settings.terminal_picker", selection: $draftSettings.terminalAccess) {
                ForEach(TerminalAccessLevel.allCases, id: \.self) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(draftSettings.terminalAccess.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if draftSettings.terminalAccess == .auto {
                autoTerminalWarningView
            }

            if draftSettings.terminalAccess != .none {
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
            }

            if draftSettings.terminalAccess != .none {
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
