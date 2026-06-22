// ProviderDetailView+Actions.swift
// Chappie
//
// Async actions: add/delete models and keys, with error propagation.

import Foundation
import ChappieCore

extension ProviderDetailView {

    // MARK: - Actions

    func addModels(_ models: [AIModel]) {
        guard let store = viewModel.providerStore else { return }
        Task {
            do {
                for model in models {
                    try await store.addModel(model, toProviderId: currentProvider.id)
                }
                viewModel.reloadProviders()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func deleteKey(id: UUID) {
        guard let store = viewModel.providerStore else { return }
        viewModel.invalidateKeyIfDeleted(keyId: id, providerId: currentProvider.id)
        Task {
            do {
                try await store.deleteKey(id: id, fromProviderId: currentProvider.id)
                viewModel.reloadProviders()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func deleteModel(_ modelId: String) {
        guard let store = viewModel.providerStore else { return }
        viewModel.invalidateModelIfDeleted(modelId: modelId, providerId: currentProvider.id)
        Task {
            do {
                try await store.deleteModel(id: modelId, fromProviderId: currentProvider.id)
                viewModel.reloadProviders()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
