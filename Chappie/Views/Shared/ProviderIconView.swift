// ProviderIconView.swift
// Chappie
//
// Reusable provider icon — SF Symbol + brand color, synced from catalog.
// Used in: CatalogPickerSheet, ProvidersSettingsView, ModelPickerRow, NewThreadProviderSheet.
//
// Custom providers (origin = .custom) fall back to "wrench.and.screwdriver" + accent color.
// Catalog providers show their assigned SF Symbol in their brand color.

import SwiftUI
import ChappieCore

// MARK: - ProviderIconView

/// Square rounded icon for a provider — SF Symbol in brand color on tinted background.
struct ProviderIconView: View {

    let iconName: String
    let iconColor: Color
    /// Size of the outer rounded square. Icon scales proportionally.
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(iconColor.opacity(0.12))
                .frame(width: size, height: size)
            Image(systemName: iconName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(iconColor)
        }
    }
}

// MARK: - AIProvider convenience

extension AIProvider {
    /// Resolved icon color — parses hex string from catalog or falls back to accent.
    var resolvedIconColor: Color {
        guard let hex = iconColor else { return .accentColor }
        return Color(hex: hex) ?? .accentColor
    }
}

// MARK: - Color(hex:)

extension Color {
    /// Parses a hex color string like "#10A37F" or "10A37F".
    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6,
              let value = UInt64(cleaned, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
