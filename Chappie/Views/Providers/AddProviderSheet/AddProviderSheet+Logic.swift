// AddProviderSheet+Logic.swift
// Chappie
//
// Business logic: prefill, validate provider, fetch models, save provider.

import SwiftUI
import ChappieCore

extension AddProviderSheet {

    // MARK: - Pre-fill on Appear

    func prefill() {
        if let provider = editingProvider {
            providerName = provider.name
            baseURL = provider.baseURL
            selectedModelIds = Set(provider.models.map { $0.id })
            apiKeyName = provider.keys.first?.name ?? ""
        } else if let preset = prefilledPreset {
            providerName = preset.name
            baseURL = preset.baseURL
        }
    }

    // MARK: - Select All Toggle

    func toggleSelectAll() {
        if allFilteredSelected { for m in filteredModels { selectedModelIds.remove(m.id) } }
        else { for m in filteredModels { selectedModelIds.insert(m.id) } }
    }

    // MARK: - Step 1: Validate Provider

    func validateAndProceed() {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespaces)
        guard !trimmedURL.isEmpty else { validationError = String(localized: "provider.url_label"); return }

        isValidating = true
        validationError = nil

        Task {
            // Duplicate host check only for presets; custom providers may share a host.
            if isPreset && !isEditing, let store = providerStore {
                let hostExists = await store.providerHostExists(trimmedURL)
                if hostExists {
                    await MainActor.run { isValidating = false; duplicateHostAlert = true }
                    return
                }
            }

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
                baseURL: trimmedURL + discoveryPrefix,
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
                    catalogId: editingProvider?.catalogId ?? prefilledPreset?.id,
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
                    if fetchedModels.isEmpty {
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

    func fetchModels() {
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
                baseURL: provider.discoveryBaseURL,
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
                        return AIModel(id: modelId, name: modelId, endpoint: provider.defaultChatPath, providerProtocol: provider.providerProtocol)
                    }
                    fetchError = nil
                    if selectedModelIds.isEmpty { selectedModelIds = Set(modelIds) }
                }
            }
        }
    }

    // MARK: - Step 2: Manual Model

    func addManualModel() {
        let trimmed = manualModelInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !fetchedModels.contains(where: { $0.id == trimmed }) {
            let proto = validatedProvider?.providerProtocol ?? effectiveProtocol
            let endpoint = validatedProvider?.defaultChatPath
                ?? prefilledPreset?.chatPath
                ?? (proto == .anthropic ? "/v1/messages" : "/v1/chat/completions")
            fetchedModels.insert(AIModel(id: trimmed, name: trimmed, endpoint: endpoint, providerProtocol: proto), at: 0)
        }
        selectedModelIds.insert(trimmed)
        manualModelInput = ""
    }

    // MARK: - Step 2: Save Provider

    func saveProvider() {
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
                    try await updateKeyIfNeeded(store: store, provider: finalProvider)

                } else if isOnboarding {
                    try await saveOnboardingProvider(store: store, provider: finalProvider, models: modelsToSave)

                } else {
                    let trimmedKeyValue = apiKeyValue.trimmingCharacters(in: .whitespaces)
                    let resolvedKeyName = apiKeyName.trimmingCharacters(in: .whitespaces)
                    try await store.addProvider(
                        finalProvider,
                        firstKeyName: resolvedKeyName.isEmpty ? "Default" : resolvedKeyName,
                        firstKeyValue: trimmedKeyValue
                    )
                }

                await MainActor.run { isSaving = false; onSaved() }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = String(format: String(localized: "provider.save_error"), error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Save Helpers

    private func updateKeyIfNeeded(store: AIProviderStore, provider: AIProvider) async throws {
        let trimmedKeyValue = apiKeyValue.trimmingCharacters(in: .whitespaces)
        let resolvedKeyName = apiKeyName.trimmingCharacters(in: .whitespaces)

        guard let firstKey = provider.keys.first else { return }

        if !resolvedKeyName.isEmpty {
            let otherKeys = provider.keys.filter { $0.id != firstKey.id }
            if otherKeys.contains(where: { $0.name.lowercased() == resolvedKeyName.lowercased() }) {
                await MainActor.run { isSaving = false; duplicateKeyNameAlert = true }
                return
            }
        }

        if !trimmedKeyValue.isEmpty {
            var valueCollision = false
            for other in provider.keys.filter({ $0.id != firstKey.id }) {
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
            forProviderId: provider.id
        )
    }

    private func saveOnboardingProvider(store: AIProviderStore, provider: AIProvider, models: [AIModel]) async throws {
        let validKeys = pendingKeys.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let firstKey = validKeys.first else {
            await MainActor.run { isSaving = false; saveError = String(localized: "provider.need_key") }
            return
        }

        let providerId = try await store.mergeProvider(
            provider,
            keyName: firstKey.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Default" : firstKey.name,
            keyValue: firstKey.value.trimmingCharacters(in: .whitespaces),
            models: models
        )

        for key in validKeys.dropFirst() {
            let name = key.name.trimmingCharacters(in: .whitespaces)
            let value = key.value.trimmingCharacters(in: .whitespaces)
            _ = try await store.mergeProvider(
                AIProvider(id: providerId, name: provider.name, baseURL: provider.baseURL),
                keyName: name.isEmpty ? "Key" : name,
                keyValue: value,
                models: []
            )
        }
    }
}
