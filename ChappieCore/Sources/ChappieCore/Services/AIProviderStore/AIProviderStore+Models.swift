// AIProviderStore+Models.swift
// ChappieCore
//
// AI model CRUD for a provider.

import Foundation

extension AIProviderStore {

    public func addModel(_ model: AIModel, toProviderId providerId: UUID) async throws {
        var providers = try await getProviders()
        guard let idx = providers.firstIndex(where: { $0.id == providerId }) else {
            throw AIProviderStoreError.notFound(providerId)
        }

        guard !model.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !providers[idx].models.contains(where: { $0.id == model.id }) else { return }

        providers[idx].models.append(model)
        try await saveProviders(providers)
        try await refreshCache()
    }

    public func deleteModel(id modelId: String, fromProviderId providerId: UUID) async throws {
        var providers = try await getProviders()
        guard let idx = providers.firstIndex(where: { $0.id == providerId }) else {
            throw AIProviderStoreError.notFound(providerId)
        }

        providers[idx].models.removeAll { $0.id == modelId }
        try await saveProviders(providers)
        try await refreshCache()
    }
}
