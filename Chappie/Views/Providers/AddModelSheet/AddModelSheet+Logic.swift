// AddModelSheet+Logic.swift
// Chappie
//
// Async model loading (provider endpoint), manual add, select-all, confirm save.

import SwiftUI
import ChappieCore

extension AddModelSheet {

    // MARK: - Provider Endpoint Fetch

    /// Fetches the model list from the provider's own /models endpoint.
    func fetchFromProvider() {
        guard let store = providerStore else { return }
        isLoading = true
        loadError = nil

        Task {
            let keySecret: String
            if let firstKey = provider.keys.first {
                keySecret = await store.loadApiKey(for: firstKey.id) ?? ""
            } else {
                keySecret = ""
            }

            guard !keySecret.isEmpty else {
                await MainActor.run {
                    isLoading = false
                    loadError = String(localized: "add_models.no_keys_error")
                }
                return
            }

            let client = AIClientFactory.makeForValidation(
                baseURL: provider.discoveryBaseURL,
                apiKey: keySecret,
                providerProtocol: provider.providerProtocol,
                authScheme: provider.authScheme
            )
            let modelIds = await client.fetchAvailableModels()

            await MainActor.run {
                isLoading = false
                if modelIds.isEmpty {
                    loadError = String(localized: "add_models.fetch_error")
                } else {
                    fetchedModels = modelIds.map { modelId in
                        if let existing = provider.models.first(where: { $0.id == modelId }) {
                            return existing
                        }
                        return AIModel(
                            id: modelId,
                            name: modelId,
                            endpoint: provider.defaultChatPath,
                            providerProtocol: provider.providerProtocol
                        )
                    }
                    for m in fetchedModels where !existingIds.contains(m.id) {
                        selectedModelIds.insert(m.id)
                    }
                }
            }
        }
    }

    // MARK: - Manual Add

    func addManual() {
        let trimmed = manualInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let allExisting = fetchedModels + manualModels
        if !allExisting.contains(where: { $0.id == trimmed }) {
            let model = AIModel(
                id: trimmed,
                name: trimmed,
                endpoint: provider.defaultChatPath,
                providerProtocol: provider.providerProtocol
            )
            manualModels.insert(model, at: 0)
        }
        if !existingIds.contains(trimmed) { selectedModelIds.insert(trimmed) }
        manualInput = ""
    }

    // MARK: - Select All Toggle

    func toggleSelectAll() {
        let selectable = filteredModels.filter { !existingIds.contains($0.id) }
        if allFilteredSelected {
            for m in selectable { selectedModelIds.remove(m.id) }
        } else {
            for m in selectable { selectedModelIds.insert(m.id) }
        }
    }

    // MARK: - Confirm Save

    func confirmSave() {
        let newModels = allModels
            .filter { selectedModelIds.contains($0.id) && !existingIds.contains($0.id) }
            .sorted { $0.id < $1.id }
        guard !newModels.isEmpty else { return }
        onSaved(newModels)
    }

    // MARK: - Private Helpers
}
