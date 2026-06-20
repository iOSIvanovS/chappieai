// ContentView+Paywall.swift
// Chappie
//
// Paywall gate — shown when licenseState is .noLicense or .expired.

import SwiftUI
import ChappieCore

extension ContentView {

    var paywallContent: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("license.paywall_title")
                .font(.title2.bold())
            Text("license.paywall_subtitle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("license.paywall_activate_button") {
                showLicenseActivation = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: 400)
        .padding(40)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showLicenseActivation) {
            LicenseActivationView(viewModel: viewModel)
        }
    }
}
