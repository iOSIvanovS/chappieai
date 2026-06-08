// TrialBannerView.swift
// Chappie
//
// Compact banner shown when user is on trial.
// Appears at the bottom of the top panel — above the chat area.
// Tapping "Upgrade" opens LicenseActivationView.

import SwiftUI
import ChappieCore

struct TrialBannerView: View {

    let daysRemaining: Int
    let onUpgrade: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge")
                .foregroundStyle(.orange)
                .font(.system(size: 13, weight: .medium))

            Text(bannerText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)

            Spacer()

            Button(action: onUpgrade) {
                Text("license.upgrade_button")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.orange, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.orange.opacity(0.4), lineWidth: 1)
        )
    }

    private var bannerText: String {
        if daysRemaining <= 0 {
            return String(localized: "license.trial_expired")
        } else if daysRemaining == 1 {
            return String(localized: "license.trial_last_day")
        } else {
            return String(format: String(localized: "license.trial_days_remaining"), daysRemaining)
        }
    }
}
