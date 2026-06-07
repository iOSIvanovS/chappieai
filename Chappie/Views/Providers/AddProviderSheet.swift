// AddProviderSheet.swift
// Chappie
//
// Two-step sheet for adding or editing an AI provider.
//
// ENTRY POINTS:
// 1. From CatalogPickerSheet (catalog row) → prefilledRemote is set.
//    Step 1 is pre-filled: name, baseURL, catalogId, providerProtocol, models.
//    Models step shows catalog models pre-selected — no network fetch to provider.
//
// 2. From CatalogPickerSheet ("Ручная настройка") → prefilledRemote is nil.
//    Blank step 1. No catalog link. User enters everything manually.
//    Protocol picker + Auth scheme picker shown — deterministic flow.
//    Auth scheme auto-switches when protocol changes, but user can override.
//    Models step: user fetches from provider or adds manually.
//
// 3. Edit mode (editingProvider != nil) → opens on step 1 pre-filled with existing data.
//
// STEP 1 — Provider:
//   Enter base URL, API key, optional provider name.
//   Custom mode: explicit protocol picker + auth scheme picker (Bearer / x-api-key / None).
//   Catalog mode: protocol and auth inferred from catalog — pickers hidden.
//   If catalog provider has requiresApiKey == false (e.g. Ollama) — key field hidden, button always enabled.
//   If auth scheme == .none — key field hidden, validation skips key check.
//
// STEP 2 — Models:
//   Catalog entry: models from catalog shown pre-selected, no fetch button.
//   Custom entry: user can fetch live list, search, select/deselect, add manually.
//   Must add at least one model to proceed.

import SwiftUI
import ChappieCore

// MARK: - PendingKey

private struct PendingKey: Identifiable {
    let id = UUID()
    var name: String = ""
    var value: String = ""
    var isVisible: Bool = false
}

// MARK: - AddProviderSheet

struct AddProviderSheet: View {

    // MARK: - Input

    let providerStore: AIProviderStore?
    var prefilledRemote: RemoteProvider? = nil
    var editingProvider: AIProvider? = nil
    var isOnboarding: Bool = false
    let onSaved: () -> Void
    let onCancel: () -> Void

    // MARK: - Step

    private enum Step { case provider, models }
    @State private var step: Step = .provider

    // MARK: - Step 1 State

    @State private var providerName: String = ""
    @State private var baseURL: String = ""
    @State private var isValidating: Bool = false
    @State private var validationError: String? = nil
    @State private var validatedProvider: AIProvider? = nil

    // Custom mode: explicit protocol + auth scheme selection.
    @State private var customProtocol: ProviderProtocol = .openai
    @State private var customAuthScheme: AuthScheme = .bearer

    // Directory mode (single key)
    @State private var apiKeyValue: String = ""
    @State private var apiKeyName: String = ""
    @State private var isKeyVisible: Bool = false

    // Onboarding mode (multi-key)
    @State private var pendingKeys: [PendingKey] = [PendingKey()]

    // MARK: - Step 2 State

    @State private var fetchedModels: [AIModel] = []
    @State private var selectedModelIds: Set<String> = []
    @State private var manualModelInput: String = ""
    @State private var isFetchingModels: Bool = false
    @State private var fetchError: String? = nil
    @State private var isSaving: Bool = false
    @State private var saveError: String? = nil
    @State private var modelSearchText: String = ""

    // MARK: - Duplicate Alerts

    @State private var duplicateHostAlert: Bool = false
    @State private var duplicateKeyValueAlert: Bool = false
    @State private var duplicateKeyNameAlert: Bool = false

    // MARK: - Computed

    private var isEditing: Bool { editingProvider != nil }
    private var isCatalog: Bool { prefilledRemote != nil }

    /// Show protocol + auth pickers only in pure Custom mode (not catalog, not editing).
    private var showCustomPickers: Bool { !isCatalog && !isEditing }

    /// Whether this provider requires an API key (from catalog flag, default true).
    private var requiresApiKey: Bool {
        editingProvider?.requiresApiKey ?? prefilledRemote?.requiresApiKey ?? true
    }

    /// Whether key field should be shown — hidden for no-auth and keyless catalog providers.
    private var showKeyField: Bool {
        if !requiresApiKey { return false }
        if showCustomPickers && customAuthScheme == .none { return false }
        return true
    }

    private var title: String { isEditing ? String(localized: "provider.edit_title") : String(localized: "provider.add_title") }

    /// Effective protocol for validation and client creation.
    private var effectiveProtocol: ProviderProtocol {
        if showCustomPickers { return customProtocol }
        if let remote = prefilledRemote {
            return remote.models.contains { $0.protocol == "anthropic" } ? .anthropic : .openai
        }
        return editingProvider?.providerProtocol ?? .openai
    }

    /// Effective auth scheme.
    private var effectiveAuthScheme: AuthScheme {
        if showCustomPickers { return customAuthScheme }
        return editingProvider?.authScheme ?? (effectiveProtocol == .anthropic ? .xApiKey : .bearer)
    }

    /// Origin for new providers — custom if no catalog, catalog otherwise.
    private var effectiveOrigin: ProviderOrigin {
        showCustomPickers ? .custom : .catalog
    }

    private var canValidate: Bool {
        let urlOk = !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
        if isEditing { return urlOk }
        // No key needed for keyless catalog providers or .none auth scheme.
        if !showKeyField { return urlOk }
        if isOnboarding {
            return urlOk && pendingKeys.contains(where: {
                !$0.value.trimmingCharacters(in: .whitespaces).isEmpty
            })
        } else {
            return urlOk && !apiKeyValue.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var allModels: [AIModel] {
        var combined = fetchedModels
        if let existing = editingProvider {
            for m in existing.models where !combined.contains(where: { $0.id == m.id }) {
                combined.insert(m, at: 0)
            }
        }
        return combined
    }

    private var filteredModels: [AIModel] {
        let q = modelSearchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allModels }
        return allModels.filter {
            $0.id.lowercased().contains(q) || $0.name.lowercased().contains(q)
        }
    }

    private var canSave: Bool { !selectedModelIds.isEmpty }

    private var allFilteredSelected: Bool {
        !filteredModels.isEmpty && filteredModels.allSatisfy { selectedModelIds.contains($0.id) }
    }

    private var firstValidKeyValue: String {
        if isOnboarding {
            return pendingKeys.first(where: { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty })?.value ?? ""
        } else {
            return apiKeyValue
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {
                Image(systemName: isEditing ? "pencil.circle" : "plus.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title2.bold())
                    Text(step == .provider ? String(localized: "provider.step1") : String(localized: "provider.step2"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { onCancel() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 20)

            Divider()

            switch step {
            case .provider: providerStep
            case .models:   modelsStep
            }

            Divider()

            footerButtons
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { prefill() }
        .alert("provider.duplicate_host_title", isPresented: $duplicateHostAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("provider.duplicate_host_message")
        }
        .alert("provider.duplicate_key_value_title", isPresented: $duplicateKeyValueAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("provider.duplicate_key_value_message")
        }
        .alert("provider.duplicate_key_name_title", isPresented: $duplicateKeyNameAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("provider.duplicate_key_name_message")
        }
    }

    // MARK: - Step 1: Provider

    private var providerStep: some View {
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
                    // No-auth hint.
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

                if let err = validationError {
                    errorBanner(err)
                }
            }
            .padding(24)
        }
    }

    // MARK: - Protocol Picker

    private var protocolPickerSection: some View {
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
    private func protocolOption(
        protocol proto: ProviderProtocol,
        title: String,
        subtitle: String,
        icon: String
    ) -> some View {
        let isSelected = customProtocol == proto
        Button {
            customProtocol = proto
            // Auto-switch auth scheme when protocol changes, but only if not already .none.
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

    private var authSchemePickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("provider.auth_label", systemImage: "key.horizontal")
                .font(.headline)

            // Three options in a row — Bearer, x-api-key, None.
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
    private func authSchemeOption(
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

    @ViewBuilder
    private func infoHint(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(.blue)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Catalog Badge

    @ViewBuilder
    private func catalogBadge(_ remote: RemoteProvider) -> some View {
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

    // MARK: - Single Key (Directory Mode)

    private var singleKeySection: some View {
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

    private var multiKeySection: some View {
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

    // MARK: - Step 2: Models

    private var modelsStep: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Fetch controls — only for custom/edit providers, not catalog
            if !isCatalog {
                HStack(spacing: 12) {
                    Button { fetchModels() } label: {
                        HStack(spacing: 6) {
                            if isFetchingModels { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.clockwise") }
                            Text(isFetchingModels ? String(localized: "provider.models_fetching") : String(localized: "provider.models_fetch"))
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isFetchingModels)

                    if !fetchedModels.isEmpty {
                        Text(String(format: String(localized: "provider.models_fetched_count"), allModels.count))
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(String(format: String(localized: "provider.models_selected_count"), selectedModelIds.count))
                        .font(.caption)
                        .foregroundStyle(selectedModelIds.isEmpty ? .orange : .secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 8)
            } else {
                HStack {
                    Text(String(format: String(localized: "provider.catalog_models_header"), allModels.count))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: String(localized: "provider.models_selected_count"), selectedModelIds.count))
                        .font(.caption)
                        .foregroundStyle(selectedModelIds.isEmpty ? .orange : .secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 8)
            }

            if let fetchErr = fetchError, fetchedModels.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(fetchErr).font(.caption).foregroundStyle(.orange)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }

            Divider()

            if !allModels.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 13))
                    TextField("provider.models_search_placeholder", text: $modelSearchText)
                        .textFieldStyle(.plain).font(.system(size: 13))
                    if !modelSearchText.isEmpty {
                        Button { modelSearchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.primary.opacity(0.04))

                Button { toggleSelectAll() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: allFilteredSelected ? "checkmark.square.fill" : "square")
                            .font(.system(size: 14))
                            .foregroundStyle(allFilteredSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                        Text(allFilteredSelected ? String(localized: "provider.models_deselect_all") : String(localized: "provider.models_select_all"))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        if !modelSearchText.isEmpty {
                            Text(String(format: String(localized: "provider.filter_count"), filteredModels.count, allModels.count))
                                .font(.system(size: 11)).foregroundStyle(.secondary.opacity(0.7))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .background(Color.primary.opacity(0.02))

                Divider()
            }

            if allModels.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "cpu").font(.system(size: 32)).foregroundStyle(.secondary.opacity(0.4))
                    Text("provider.models_empty").font(.subheadline).foregroundStyle(.secondary)
                    Text("provider.models_empty_hint")
                        .font(.caption).foregroundStyle(.secondary.opacity(0.7)).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 32)
            } else if filteredModels.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 28)).foregroundStyle(.secondary.opacity(0.4))
                    Text("provider.models_nothing_found").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredModels) { model in
                            ModelCheckRow(
                                model: model,
                                isSelected: selectedModelIds.contains(model.id),
                                onToggle: {
                                    if selectedModelIds.contains(model.id) { selectedModelIds.remove(model.id) }
                                    else { selectedModelIds.insert(model.id) }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
                .frame(maxHeight: 240)
            }

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "keyboard").foregroundStyle(.secondary)
                TextField("provider.models_manual_placeholder", text: $manualModelInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { addManualModel() }
                Button("common.add") { addManualModel() }
                    .buttonStyle(.bordered)
                    .disabled(manualModelInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 24).padding(.vertical, 12)

            if let err = saveError {
                errorBanner(err).padding(.horizontal, 24).padding(.bottom, 8)
            }
        }
    }

    // MARK: - Footer Buttons

    private var footerButtons: some View {
        HStack {
            Button(step == .provider ? String(localized: "provider.cancel") : String(localized: "provider.back")) {
                if step == .provider { onCancel() }
                else { withAnimation { step = .provider } }
            }
            .keyboardShortcut(.escape)

            Spacer()

            if step == .provider {
                Button { validateAndProceed() } label: {
                    HStack(spacing: 6) {
                        if isValidating { ProgressView().controlSize(.small); Text("provider.checking") }
                        else { Text("provider.next"); Image(systemName: "arrow.right") }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canValidate || isValidating)
                .keyboardShortcut(.return)
            } else {
                Button { saveProvider() } label: {
                    HStack(spacing: 6) {
                        if isSaving { ProgressView().controlSize(.small); Text("provider.saving") }
                        else { Text(isEditing ? String(localized: "provider.save") : String(localized: "provider.add_title")) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave || isSaving)
                .keyboardShortcut(.return)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    // MARK: - Field Section Builder

    @ViewBuilder
    private func fieldSection<Content: View>(
        label: String, icon: String, hint: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: icon).font(.headline)
            content()
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            Text(message).font(.subheadline).foregroundStyle(.red)
        }
        .padding(12)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Pre-fill

    private func prefill() {
        if let provider = editingProvider {
            providerName = provider.name
            baseURL = provider.baseURL
            selectedModelIds = Set(provider.models.map { $0.id })
            apiKeyName = provider.keys.first?.name ?? ""
        } else if let remote = prefilledRemote {
            providerName = remote.name
            baseURL = remote.baseURL
            // Catalog models come from providers.json — no network fetch needed
            let catalogModels = remote.models.map { rm in
                AIModel(
                    id: rm.id,
                    name: rm.name,
                    endpoint: rm.endpoint,
                    providerProtocol: rm.protocol == "anthropic" ? .anthropic : .openai
                )
            }
            fetchedModels = catalogModels
            selectedModelIds = Set(catalogModels.map { $0.id })
        }
    }

    // MARK: - Select All Toggle

    private func toggleSelectAll() {
        if allFilteredSelected { for m in filteredModels { selectedModelIds.remove(m.id) } }
        else { for m in filteredModels { selectedModelIds.insert(m.id) } }
    }

    // MARK: - Step 1: Validate Provider

    private func validateAndProceed() {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespaces)
        guard !trimmedURL.isEmpty else { validationError = String(localized: "provider.url_label"); return }

        isValidating = true
        validationError = nil

        Task {
            // Duplicate host check only for catalog providers.
            if isCatalog && !isEditing, let store = providerStore {
                let hostExists = await store.providerHostExists(trimmedURL)
                if hostExists {
                    await MainActor.run { isValidating = false; duplicateHostAlert = true }
                    return
                }
            }

            // Determine key to use — empty for no-auth providers.
            let keyToUse: String
            if !showKeyField {
                keyToUse = ""
            } else if isEditing && firstValidKeyValue.isEmpty, let existing = editingProvider,
               let store = providerStore, let firstKeyId = existing.keys.first?.id {
                keyToUse = await store.loadApiKey(for: firstKeyId) ?? ""
            } else {
                keyToUse = firstValidKeyValue
            }

            if showKeyField && keyToUse.isEmpty {
                await MainActor.run { isValidating = false; validationError = String(localized: "provider.key_value_label") }
                return
            }

            let client = AIClientFactory.makeForValidation(
                baseURL: trimmedURL,
                apiKey: keyToUse,
                providerProtocol: effectiveProtocol,
                authScheme: effectiveAuthScheme
            )

            do {
                try await client.validateProvider()

                let provisional = AIProvider(
                    id: editingProvider?.id ?? UUID(),
                    name: providerName.trimmingCharacters(in: .whitespaces),
                    baseURL: trimmedURL,
                    catalogId: editingProvider?.catalogId ?? prefilledRemote?.id,
                    providerProtocol: effectiveProtocol,
                    authScheme: effectiveAuthScheme,
                    origin: editingProvider?.origin ?? effectiveOrigin,
                    requiresApiKey: showKeyField,
                    keys: editingProvider?.keys ?? [],
                    models: editingProvider?.models ?? []
                )

                await MainActor.run {
                    isValidating = false
                    validatedProvider = provisional
                    withAnimation { step = .models }
                    // For custom providers only — fetch models if list is empty
                    if !isCatalog && fetchedModels.isEmpty {
                        fetchModels()
                    }
                }

            } catch {
                await MainActor.run {
                    isValidating = false
                    validationError = String(format: String(localized: "provider.connection_error"), error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Step 2: Fetch Models (Custom providers only)

    private func fetchModels() {
        guard let provider = validatedProvider ?? editingProvider.map({
            AIProvider(
                id: $0.id, name: $0.name,
                baseURL: baseURL.trimmingCharacters(in: .whitespaces),
                catalogId: $0.catalogId,
                providerProtocol: $0.providerProtocol,
                authScheme: $0.authScheme,
                keys: $0.keys, models: $0.models
            )
        }) else { return }

        isFetchingModels = true
        fetchError = nil

        Task {
            let keyToUse: String
            if !showKeyField {
                keyToUse = ""
            } else if isEditing && firstValidKeyValue.isEmpty, let existing = editingProvider,
               let store = providerStore, let firstKeyId = existing.keys.first?.id {
                keyToUse = await store.loadApiKey(for: firstKeyId) ?? ""
            } else {
                keyToUse = firstValidKeyValue
            }

            let client = AIClientFactory.makeForValidation(
                baseURL: provider.baseURL,
                apiKey: keyToUse,
                providerProtocol: provider.providerProtocol,
                authScheme: provider.authScheme
            )
            let modelIds = await client.fetchAvailableModels()

            await MainActor.run {
                isFetchingModels = false
                if modelIds.isEmpty {
                    if fetchedModels.isEmpty {
                        fetchError = String(localized: "add_models.fetch_error")
                    }
                } else {
                    let existingModels = fetchedModels
                    fetchedModels = modelIds.map { modelId in
                        if let existing = existingModels.first(where: { $0.id == modelId }) { return existing }
                        if let existing = provider.models.first(where: { $0.id == modelId }) { return existing }
                        return AIModel(id: modelId, name: modelId, endpoint: "/v1/chat/completions", providerProtocol: provider.providerProtocol)
                    }
                    fetchError = nil
                    if selectedModelIds.isEmpty { selectedModelIds = Set(modelIds) }
                }
            }
        }
    }

    // MARK: - Step 2: Manual Model

    private func addManualModel() {
        let trimmed = manualModelInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !fetchedModels.contains(where: { $0.id == trimmed }) {
            let proto = validatedProvider?.providerProtocol ?? effectiveProtocol
            let endpoint = proto == .anthropic ? "/v1/messages" : "/v1/chat/completions"
            fetchedModels.insert(AIModel(id: trimmed, name: trimmed, endpoint: endpoint, providerProtocol: proto), at: 0)
        }
        selectedModelIds.insert(trimmed)
        manualModelInput = ""
    }

    // MARK: - Step 2: Save Provider

    private func saveProvider() {
        guard let store = providerStore,
              let provisional = validatedProvider ?? editingProvider else { return }

        isSaving = true
        saveError = nil

        let modelsToSave = allModels.filter { selectedModelIds.contains($0.id) }

        Task {
            do {
                var finalProvider = provisional
                finalProvider.models = modelsToSave

                if isEditing {
                    try await store.updateProvider(finalProvider)

                    let trimmedKeyValue = apiKeyValue.trimmingCharacters(in: .whitespaces)
                    let resolvedKeyName = apiKeyName.trimmingCharacters(in: .whitespaces)

                    if let firstKey = finalProvider.keys.first {
                        if !resolvedKeyName.isEmpty {
                            let otherKeys = finalProvider.keys.filter { $0.id != firstKey.id }
                            if otherKeys.contains(where: { $0.name.lowercased() == resolvedKeyName.lowercased() }) {
                                await MainActor.run { isSaving = false; duplicateKeyNameAlert = true }
                                return
                            }
                        }
                        if !trimmedKeyValue.isEmpty {
                            var valueCollision = false
                            for other in finalProvider.keys.filter({ $0.id != firstKey.id }) {
                                if let stored = await store.loadApiKey(for: other.id), stored == trimmedKeyValue {
                                    valueCollision = true; break
                                }
                            }
                            if valueCollision {
                                await MainActor.run { isSaving = false; duplicateKeyValueAlert = true }
                                return
                            }
                        }
                        var updatedKey = firstKey
                        if !resolvedKeyName.isEmpty { updatedKey.name = resolvedKeyName }
                        try await store.updateKey(
                            updatedKey,
                            newValue: trimmedKeyValue.isEmpty ? nil : trimmedKeyValue,
                            forProviderId: finalProvider.id
                        )
                    }

                } else if isOnboarding {
                    let validKeys = pendingKeys.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
                    guard let firstKey = validKeys.first else {
                        await MainActor.run { isSaving = false; saveError = String(localized: "provider.need_key") }
                        return
                    }
                    let providerId = try await store.mergeProvider(
                        finalProvider,
                        keyName: firstKey.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Default" : firstKey.name,
                        keyValue: firstKey.value.trimmingCharacters(in: .whitespaces),
                        models: modelsToSave
                    )
                    for key in validKeys.dropFirst() {
                        let name = key.name.trimmingCharacters(in: .whitespaces)
                        let value = key.value.trimmingCharacters(in: .whitespaces)
                        _ = try await store.mergeProvider(
                            AIProvider(id: providerId, name: finalProvider.name, baseURL: finalProvider.baseURL),
                            keyName: name.isEmpty ? "Key" : name,
                            keyValue: value,
                            models: []
                        )
                    }

                } else {
                    // Save provider — with or without key depending on auth scheme.
                    let trimmedKeyValue = apiKeyValue.trimmingCharacters(in: .whitespaces)
                    let resolvedKeyName = apiKeyName.trimmingCharacters(in: .whitespaces)
                    try await store.addProvider(
                        finalProvider,
                        firstKeyName: resolvedKeyName.isEmpty ? "Default" : resolvedKeyName,
                        firstKeyValue: trimmedKeyValue  // empty string for keyless providers
                    )
                }

                await MainActor.run { isSaving = false; onSaved() }
            } catch {
                await MainActor.run { isSaving = false; saveError = String(format: String(localized: "provider.save_error"), error.localizedDescription) }
            }
        }
    }
}

// MARK: - PendingKeyRow

private struct PendingKeyRow: View {
    @Binding var key: PendingKey
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("provider.key_name_label", text: $key.name)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                Group {
                    if key.isVisible { TextField("sk-...", text: $key.value) }
                    else { SecureField("sk-...", text: $key.value) }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                Button { key.isVisible.toggle() } label: {
                    Image(systemName: key.isVisible ? "eye.slash" : "eye").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                if canDelete {
                    Button(action: onDelete) {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - ModelCheckRow

private struct ModelCheckRow: View {
    let model: AIModel
    let isSelected: Bool
    let onToggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
                Text(model.displayName)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.primary).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.07) : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Preview

#Preview {
    AddProviderSheet(providerStore: nil, onSaved: {}, onCancel: {})
}
