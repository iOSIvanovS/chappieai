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
// Decomposed into:
//   AddProviderSheet+Step1.swift   — Step 1 UI (URL, name, key fields)
//   AddProviderSheet+Pickers.swift — Protocol + Auth scheme pickers
//   AddProviderSheet+Step2.swift   — Step 2 UI (models list)
//   AddProviderSheet+Logic.swift   — prefill, validate, fetch, save
//   AddProviderSheetComponents.swift — PendingKey, PendingKeyRow, ModelCheckRow

import SwiftUI
import ChappieCore

struct AddProviderSheet: View {

    // MARK: - Input

    let providerStore: AIProviderStore?
    var prefilledRemote: RemoteProvider? = nil
    var editingProvider: AIProvider? = nil
    var isOnboarding: Bool = false
    let onSaved: () -> Void
    let onCancel: () -> Void

    // MARK: - Step

    enum Step { case provider, models }
    @State var step: Step = .provider

    // MARK: - Step 1 State

    @State var providerName: String = ""
    @State var baseURL: String = ""
    @State var isValidating: Bool = false
    @State var validationError: String? = nil
    @State var validatedProvider: AIProvider? = nil

    @State var customProtocol: ProviderProtocol = .openai
    @State var customAuthScheme: AuthScheme = .bearer

    @State var apiKeyValue: String = ""
    @State var apiKeyName: String = ""
    @State var isKeyVisible: Bool = false

    @State var pendingKeys: [PendingKey] = [PendingKey()]

    // MARK: - Step 2 State

    @State var fetchedModels: [AIModel] = []
    @State var selectedModelIds: Set<String> = []
    @State var manualModelInput: String = ""
    @State var isFetchingModels: Bool = false
    @State var fetchError: String? = nil
    @State var isSaving: Bool = false
    @State var saveError: String? = nil
    @State var modelSearchText: String = ""

    // MARK: - Duplicate Alerts

    @State var duplicateHostAlert: Bool = false
    @State var duplicateKeyValueAlert: Bool = false
    @State var duplicateKeyNameAlert: Bool = false

    // MARK: - Computed

    var isEditing: Bool { editingProvider != nil }
    var isCatalog: Bool { prefilledRemote != nil }

    var showCustomPickers: Bool { !isCatalog && !isEditing }

    var requiresApiKey: Bool {
        editingProvider?.requiresApiKey ?? prefilledRemote?.requiresApiKey ?? true
    }

    var showKeyField: Bool {
        if !requiresApiKey { return false }
        if showCustomPickers && customAuthScheme == .none { return false }
        return true
    }

    private var title: String { isEditing ? String(localized: "provider.edit_title") : String(localized: "provider.add_title") }

    var effectiveProtocol: ProviderProtocol {
        if showCustomPickers { return customProtocol }
        if let remote = prefilledRemote {
            return remote.models.contains { $0.protocol == "anthropic" } ? .anthropic : .openai
        }
        return editingProvider?.providerProtocol ?? .openai
    }

    var effectiveAuthScheme: AuthScheme {
        if showCustomPickers { return customAuthScheme }
        return editingProvider?.authScheme ?? (effectiveProtocol == .anthropic ? .xApiKey : .bearer)
    }

    var effectiveOrigin: ProviderOrigin {
        showCustomPickers ? .custom : .catalog
    }

    var canValidate: Bool {
        let urlOk = !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
        if isEditing { return urlOk }
        if !showKeyField { return urlOk }
        if isOnboarding {
            return urlOk && pendingKeys.contains(where: {
                !$0.value.trimmingCharacters(in: .whitespaces).isEmpty
            })
        } else {
            return urlOk && !apiKeyValue.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var allModels: [AIModel] {
        var combined = fetchedModels
        if let existing = editingProvider {
            for m in existing.models where !combined.contains(where: { $0.id == m.id }) {
                combined.insert(m, at: 0)
            }
        }
        return combined
    }

    var filteredModels: [AIModel] {
        let q = modelSearchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allModels }
        return allModels.filter {
            $0.id.lowercased().contains(q) || $0.name.lowercased().contains(q)
        }
    }

    var canSave: Bool { !selectedModelIds.isEmpty }

    var allFilteredSelected: Bool {
        !filteredModels.isEmpty && filteredModels.allSatisfy { selectedModelIds.contains($0.id) }
    }

    var firstValidKeyValue: String {
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

    // MARK: - Footer Buttons

    var footerButtons: some View {
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
}

// MARK: - Preview

#Preview {
    AddProviderSheet(providerStore: nil, onSaved: {}, onCancel: {})
}
