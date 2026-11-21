// ThreadSettingsSheet+ComputerUse.swift
// Chappie
//
// Computer Use switch section for ThreadSettingsSheet.

import SwiftUI
import ChappieCore

extension ThreadSettingsSheet {

    // MARK: - Computer Use Section

    var computerUseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("thread.settings.computer_use_section", systemImage: "computermouse.fill")

            Toggle("thread.settings.computer_use_toggle", isOn: $draftSettings.computerUseEnabled)
                .toggleStyle(.switch)

            Text("thread.settings.computer_use_toggle_description")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if draftSettings.computerUseEnabled {
                computerUseWarningView
                computerUsePrivacyView
            }
        }
    }

    // MARK: - Warning Views

    var computerUseWarningView: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .padding(.top, 1)

            Text("thread.settings.computer_use_auto_warning")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    var computerUsePrivacyView: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "eye.fill")
                .font(.system(size: 12))
                .foregroundStyle(.blue)
                .padding(.top, 1)

            Text("thread.settings.computer_use_privacy_hint")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.blue.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
