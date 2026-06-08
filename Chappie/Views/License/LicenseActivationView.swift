// LicenseActivationView.swift
// Chappie
//
// Sheet for entering and activating the owner JWT token.
// Shown from SettingsView — user pastes JWT, taps Activate.

import SwiftUI

struct LicenseActivationView: View {

    @Environment(\.dismiss) private var dismiss
    var viewModel: ChappieViewModel

    @State private var jwt: String = ""
    @State private var isActivating: Bool = false
    @State private var errorMessage: String? = nil
    @State private var didSucceed: Bool = false

    var body: some View {
        VStack(spacing: 24) {

            // Header
            VStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.yellow)
                Text("license.activate_title")
                    .font(.title2.bold())
                Text("license.jwt_token_hint")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)

            // JWT input
            VStack(alignment: .leading, spacing: 6) {
                Text("license.jwt_token_label")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $jwt)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 100)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            }

            // Error
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            // Success
            if didSucceed {
                Label("license.activated_success", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline.bold())
            }

            // Buttons
            HStack(spacing: 12) {
                Button("common.cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .disabled(isActivating)

                Button {
                    activate()
                } label: {
                    if isActivating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("license.activate_button")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(jwt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isActivating || didSucceed)
            }
        }
        .padding(28)
        .frame(width: 420)
    }

    private func activate() {
        let token = jwt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }

        isActivating = true
        errorMessage = nil

        Task {
            let success = await viewModel.activateOwnerLicense(jwt: token)
            isActivating = false
            if success {
                didSucceed = true
                // Auto-dismiss after short delay so user sees the success state
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                dismiss()
            } else {
                errorMessage = String(localized: "license.activation_error")
            }
        }
    }
}
