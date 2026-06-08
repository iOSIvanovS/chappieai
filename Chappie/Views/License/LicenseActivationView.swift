// LicenseActivationView.swift
// Chappie
//
// Activation sheet: shows plans with Buy buttons + key entry field.
// Owner JWT path is kept for admin use.

import SwiftUI

struct LicenseActivationView: View {

    @Environment(\.dismiss) private var dismiss
    var viewModel: ChappieViewModel

    @State private var licenseKey: String = ""
    @State private var isActivating: Bool = false
    @State private var errorMessage: String? = nil
    @State private var didSucceed: Bool = false
    @State private var showOwnerJWT: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                headerSection
                plansSection
                activationSection
                if showOwnerJWT { ownerJWTSection }
            }
            .padding(28)
        }
        .frame(width: 460)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 6) {
            Image(systemName: "crown.fill")
                .font(.system(size: 36))
                .foregroundStyle(.yellow)
            Text("license.choose_plan_title")
                .font(.title2.bold())
            Text("license.choose_plan_subtitle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 4)
    }

    // MARK: - Plans

    private var plansSection: some View {
        VStack(spacing: 10) {
            PlanRowView(
                name: String(localized: "license.plan_starter_name"),
                description: String(localized: "license.plan_starter_desc"),
                badge: String(localized: "license.plan_devices_1"),
                productId: "f6adaa01-d4ca-4dc6-bc5e-540abc3c8d18"
            )
            PlanRowView(
                name: String(localized: "license.plan_pro_name"),
                description: String(localized: "license.plan_pro_desc"),
                badge: String(localized: "license.plan_devices_1"),
                productId: "f94c5cd4-d64b-41fa-bd23-5a31bae104fa",
                isHighlighted: true
            )
            PlanRowView(
                name: String(localized: "license.plan_team_name"),
                description: String(localized: "license.plan_team_desc"),
                badge: String(localized: "license.plan_devices_5"),
                productId: "d4398701-652f-4e8f-9b2e-46d57c803003"
            )
        }
    }

    // MARK: - Key Activation

    private var activationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("license.enter_key_label")
                .font(.subheadline.bold())

            HStack(spacing: 8) {
                TextField("license.enter_key_placeholder", text: $licenseKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(isActivating || didSucceed)

                Button {
                    activateKey()
                } label: {
                    if isActivating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("license.activate_button")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isActivating || didSucceed)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if didSucceed {
                Label("license.activated_success", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption.bold())
            }
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Owner JWT (hidden, tap 3x on header icon to reveal)

    private var ownerJWTSection: some View {
        OwnerJWTSectionView(viewModel: viewModel, onSuccess: { dismiss() })
    }

    // MARK: - Actions

    private func activateKey() {
        let key = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        isActivating = true
        errorMessage = nil

        Task {
            do {
                _ = try await viewModel.activateLicense(key: key)
                isActivating = false
                didSucceed = true
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                dismiss()
            } catch {
                isActivating = false
                errorMessage = String(localized: "license.activation_error")
            }
        }
    }
}

// MARK: - PlanRowView

private struct PlanRowView: View {

    let name: String
    let description: String
    let badge: String
    let productId: String
    var isHighlighted: Bool = false

    private var buyURL: URL {
        URL(string: "https://chappieai.ru/buy?product=\(productId)")!
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.subheadline.bold())
                    if isHighlighted {
                        Text("license.plan_popular_badge")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.yellow.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(badge)
                .font(.caption)
                .foregroundStyle(.secondary)

            Link(destination: buyURL) {
                Text("license.buy_button")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(isHighlighted ? Color.accentColor : Color.accentColor.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(isHighlighted ? .white : .accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isHighlighted ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }
}

// MARK: - OwnerJWTSectionView

private struct OwnerJWTSectionView: View {

    var viewModel: ChappieViewModel
    var onSuccess: () -> Void

    @State private var jwt: String = ""
    @State private var isActivating: Bool = false
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("license.jwt_token_label")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            TextEditor(text: $jwt)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 80)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button {
                activateOwner()
            } label: {
                if isActivating {
                    ProgressView().controlSize(.small)
                } else {
                    Text("license.activate_button")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(jwt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isActivating)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func activateOwner() {
        let token = jwt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        isActivating = true
        Task {
            let success = await viewModel.activateOwnerLicense(jwt: token)
            isActivating = false
            if success {
                try? await Task.sleep(nanoseconds: 800_000_000)
                onSuccess()
            } else {
                errorMessage = String(localized: "license.activation_error")
            }
        }
    }
}
