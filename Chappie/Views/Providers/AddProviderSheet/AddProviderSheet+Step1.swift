// AddProviderSheet+Step1.swift
// Chappie
//
// Step 1 UI: provider URL, name, key fields, catalog badge, error banner.

import SwiftUI
import ChappieCore

extension AddProviderSheet {

    // MARK: - Step 1: Provider

    var providerStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                if let remote = prefilledRemote {
                    catalogBadge(remote)
                }

                fieldSection(label: String(localized: "provider.name_label"), icon: "tag", hint: String(localized: "provider.name_hint")) {
                    TextField("provider.name_placeholder", text: $providerName)
                        .textFieldStyle(.roundedBorder)
                }

                fieldSection(label: String(localized: "provider.base_url_label"), icon: "link", hint: String(localized: "provider.base_url_hint")) {
                    TextField("https://...", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .disabled(isCatalog && !isEditing)
                        .foregroundStyle(isCatalog && !isEditing ? .secondary : .primary)
                }

                // Protocol + Auth pickers — only in Custom mode.
                if showCustomPickers {
                    protocolPickerSection
                    authSchemePickerSection
                }

                // Key section — hidden for no-auth providers and .none auth scheme.
                if showKeyField {
                    if isOnboarding {
                        multiKeySection
                    } else {
                        singleKeySection
                    }
                } else {
                    noAuthHint
                }

                if let err = validationError {
                    errorBanner(err)
                }
            }
            .padding(24)
        }
    }

    // MARK: - No-Auth Hint

    private var noAuthHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(
                customAuthScheme == .none
                    ? String(localized: "provider.auth_none_subtitle")
                    : String(localized: "provider.no_auth_local_hint")
            )
            .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Single Key (Directory Mode)

    var singleKeySection: some View {
        Group {
            fieldSection(
                label: String(localized: "provider.key_name_label"),
                icon: "tag.fill",
                hint: String(localized: "provider.key_name_hint")
            ) {
                TextField(isEditing ? String(localized: "edit_key.value_placeholder_edit") : String(localized: "provider.key_name_label"), text: $apiKeyName)
                    .textFieldStyle(.roundedBorder)
            }

            fieldSection(
                label: String(localized: "provider.api_key_label"),
                icon: "key.fill",
                hint: isEditing ? String(localized: "provider.key_value_hint_edit") : String(localized: "provider.key_value_hint_add")
            ) {
                HStack(spacing: 8) {
                    Group {
                        if isKeyVisible {
                            TextField(isEditing ? String(localized: "edit_key.value_placeholder_edit") : "sk-...", text: $apiKeyValue)
                        } else {
                            SecureField(isEditing ? String(localized: "edit_key.value_placeholder_edit") : "sk-...", text: $apiKeyValue)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                    Button { isKeyVisible.toggle() } label: {
                        Image(systemName: isKeyVisible ? "eye.slash" : "eye").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Multi-Key (Onboarding Mode)

    var multiKeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("provider.api_keys_label", systemImage: "key.fill").font(.headline)

            Text("provider.need_key")
                .font(.caption).foregroundStyle(.secondary)

            ForEach($pendingKeys) { $key in
                PendingKeyRow(key: $key, canDelete: pendingKeys.count > 1) {
                    pendingKeys.removeAll { $0.id == key.id }
                }
            }

            Button { pendingKeys.append(PendingKey()) } label: {
                Label("provider.add_key", systemImage: "plus.circle").font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }

    // MARK: - Catalog Badge

    @ViewBuilder
    func catalogBadge(_ remote: RemoteProvider) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: String(localized: "provider.catalog_badge"), remote.name))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(String(format: String(localized: "provider.catalog_models_count"), remote.models.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Shared Field Builder

    @ViewBuilder
    func fieldSection<Content: View>(
        label: String, icon: String, hint: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: icon).font(.headline)
            content()
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Error Banner

    @ViewBuilder
    func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            Text(message).font(.subheadline).foregroundStyle(.red)
        }
        .padding(12)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
