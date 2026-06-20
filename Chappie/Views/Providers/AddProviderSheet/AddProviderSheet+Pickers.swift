// AddProviderSheet+Pickers.swift
// Chappie
//
// Protocol picker and Auth scheme picker — shown only in Custom (non-catalog) mode.

import SwiftUI
import ChappieCore

extension AddProviderSheet {

    // MARK: - Protocol Picker

    var protocolPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("provider.protocol_label", systemImage: "network")
                .font(.headline)

            HStack(spacing: 12) {
                protocolOption(
                    protocol: .openai,
                    title: String(localized: "provider.protocol_openai_title"),
                    subtitle: String(localized: "provider.protocol_openai_subtitle"),
                    icon: "bolt.circle"
                )
                protocolOption(
                    protocol: .anthropic,
                    title: "Anthropic",
                    subtitle: String(localized: "provider.protocol_anthropic_subtitle"),
                    icon: "atom"
                )
            }

            Text("provider.protocol_hint")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    func protocolOption(
        protocol proto: ProviderProtocol,
        title: String,
        subtitle: String,
        icon: String
    ) -> some View {
        let isSelected = customProtocol == proto
        Button {
            customProtocol = proto
            // Auto-switch auth scheme when protocol changes, but preserve .none if user set it.
            if customAuthScheme != .none {
                customAuthScheme = proto == .anthropic ? .xApiKey : .bearer
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.07) : Color.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Auth Scheme Picker

    var authSchemePickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("provider.auth_label", systemImage: "key.horizontal")
                .font(.headline)

            HStack(spacing: 8) {
                authSchemeOption(
                    scheme: .bearer,
                    title: "Bearer Token",
                    subtitle: "Authorization: Bearer {key}",
                    icon: "lock.shield"
                )
                authSchemeOption(
                    scheme: .xApiKey,
                    title: "x-api-key",
                    subtitle: "x-api-key: {key}",
                    icon: "key.fill"
                )
                authSchemeOption(
                    scheme: .none,
                    title: String(localized: "provider.auth_none_title"),
                    subtitle: String(localized: "provider.auth_none_subtitle"),
                    icon: "lock.open"
                )
            }

            // Contextual hints for unusual combinations.
            if customProtocol == .anthropic && customAuthScheme == .bearer {
                infoHint(String(localized: "provider.auth_bearer_nonstandard_hint"))
            } else if customProtocol == .openai && customAuthScheme == .xApiKey {
                infoHint(String(localized: "provider.auth_xapikey_nonstandard_hint"))
            } else if customAuthScheme == .none {
                infoHint(String(localized: "provider.no_auth_none_hint"))
            }
        }
    }

    @ViewBuilder
    func authSchemeOption(
        scheme: AuthScheme,
        title: String,
        subtitle: String,
        icon: String
    ) -> some View {
        let isSelected = customAuthScheme == scheme
        Button {
            customAuthScheme = scheme
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.07) : Color.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Info Hint

    @ViewBuilder
    func infoHint(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(.blue)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}
