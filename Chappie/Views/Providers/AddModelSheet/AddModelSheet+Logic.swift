// AddModelSheet+Logic.swift
// Chappie
//
// Async model loading (catalog + provider endpoint), manual add, select-all, confirm save.

import SwiftUI
import ChappieCore

extension AddModelSheet {

    // MARK: - Load Entry Point

    func loadModels() {
        if isCatalog { loadFromCatalog() }
        // Custom providers: don't auto-fetch — user taps button explicitly
    }

    // MARK: - Catalog Load

    /// Loads models from remote catalog for catalog-linked providers.
    func loadFromCatalog() {
        guard let catalogId = provider.catalogId,
              let service = remoteService else { return }
        isLoading = true
        loadError = nil

        Task {
            // Try cached catalog first
            if let remote = await service.findProvider(byCatalogId: catalogId) {
                let models = mapRemoteModels(remote.models)
                await MainActor.run { applyLoadedModels(models, to: &catalogModels) }
            } else {
                // Catalog not cached yet — fetch fresh
                do {
                    let catalog = try await service.fetchCatalog()
                    if let remote = catalog.providers.first(where: { $0.id == catalogId }) {
                        let models = mapRemoteModels(remote.models)
                        await MainActor.run { applyLoadedModels(models, to: &catalogModels) }
                    } else {
                        await MainActor.run {
                            isLoading = false
                            loadError = String(localized: "add_models.catalog_error")
                        }
                    }
                } catch {
                    await MainActor.run {
                        isLoading = false
                        loadError = String(format: String(localized: "add_models.catalog_fetch_error"),
                                          error.localizedDescription)
                    }
                }
            }
        }
    }

    // MARK: - Provider Endpoint Fetch

    /// Fetches models from provider endpoint — only for custom providers.
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
                baseURL: provider.baseURL,
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
                            endpoint: "/v1/chat/completions",
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
        let allExisting = catalogModels + fetchedModels + manualModels
        if !allExisting.contains(where: { $0.id == trimmed }) {
            let model = AIModel(
                id: trimmed,
                name: trimmed,
                endpoint: provider.providerProtocol == .anthropic ? "/v1/messages" : "/v1/chat/completions",
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

    private func mapRemoteModels(_ remoteModels: [RemoteModel]) -> [AIModel] {
        remoteModels.map { rm in
            AIModel(
                id: rm.id,
                name: rm.name,
                endpoint: rm.endpoint,
                providerProtocol: rm.protocol == "anthropic" ? .anthropic : .openai
            )
        }
    }

    /// Applies loaded models to target array and auto-selects new ones.
    private func applyLoadedModels(_ models: [AIModel], to target: inout [AIModel]) {
        target = models
        isLoading = false
        for m in models where !existingIds.contains(m.id) {
            selectedModelIds.insert(m.id)
        }
    }
}
