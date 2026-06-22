// CatalogPickerSheet+Rows.swift
// Chappie
//
// Row components for CatalogPickerSheet:
// - CatalogProviderRow: known provider from remote catalog
// - CustomProviderRow: manual setup fallback

import SwiftUI
import ChappieCore

// MARK: - CatalogProviderRow

struct CatalogProviderRow: View {

    let remote: RemoteProvider
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                ProviderIconView(
                    iconName: remote.iconName,
                    iconColor: Color(hex: remote.iconColor ?? "") ?? .accentColor,
                    size: 36
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(remote.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    HStack(spacing: 6) {
                        Text(URL(string: remote.baseURL)?.host ?? remote.baseURL)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        Text("common.separator_dot")
                            .foregroundStyle(.secondary.opacity(0.4))

                        Text(verbatim: "\(remote.models.count) \(modelsLabel(remote.models.count))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(isHovered ? 0.6 : 0.3))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private func modelsLabel(_ count: Int) -> String {
        switch count % 10 {
        case 1 where count % 100 != 11: return String(localized: "format.model_singular")
        case 2...4 where !(11...14).contains(count % 100): return String(localized: "format.model_few")
        default: return String(localized: "format.model_many")
        }
    }
}

// MARK: - CustomProviderRow

struct CustomProviderRow: View {

    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: 36, height: 36)
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("catalog.custom_title")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("catalog.custom_subtitle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(isHovered ? 0.6 : 0.3))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
