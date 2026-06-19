// AIProviderStore+Catalog.swift
// ChappieCore
//
// Add/merge providers from remote catalog + onboarding merge flow.

import Foundation

extension AIProviderStore {

    // MARK: - Add Provider

    @discardableResult
    public func addProvider(
        _ provider: AIProvider,
        firstKeyName: String,
        firstKeyValue: String
    ) async throws -> UUID {
        var providers = try await getProviders()
        var providerWithKey = provider

        if provider.requiresApiKey {
            let firstKey = APIKey(name: firstKeyName.isEmpty ? "Default" : firstKeyName)
            saveApiKey(firstKeyValue, for: firstKey.id)
            providerWithKey.keys = [firstKey]
        }

        if providers.isEmpty { providerWithKey.isDefault = true }

        providers.append(providerWithKey)
        try await saveProviders(providers)
        try await refreshCache()

        print("[AIProviderStore] Added provider '\(providerWithKey.displayName)'")
        return providerWithKey.id
    }

    // MARK: - Add from Catalog

    @discardableResult
    public func addFromCatalog(
        _ remote: RemoteProvider,
        keyName: String,
        keyValue: String,
        selectedModelIds: Set<String>? = nil
    ) async throws -> UUID {
        let existing = try await getProviders()

        if let matched = existing.first(where: { $0.catalogId == remote.id }) {
            return try await mergeIntoCatalogProvider(
                matched,
                remote: remote,
                keyName: keyName,
                keyValue: keyValue,
                selectedModelIds: selectedModelIds
            )
        }

        let allModels = buildModels(from: remote, selectedIds: selectedModelIds)
        let provider = AIProvider(
            name: remote.name,
            baseURL: remote.baseURL,
            catalogId: remote.id,
            providerProtocol: dominantProtocol(in: remote),
            origin: .catalog,
            requiresApiKey: remote.requiresApiKey,
            iconName: remote.iconName,
            iconColor: remote.iconColor,
            models: allModels
        )

        return try await addProvider(provider, firstKeyName: keyName, firstKeyValue: keyValue)
    }

    private func mergeIntoCatalogProvider(
        _ existing: AIProvider,
        remote: RemoteProvider,
        keyName: String,
        keyValue: String,
        selectedModelIds: Set<String>?
    ) async throws -> UUID {
        var updated = existing

        if remote.requiresApiKey {
            let trimmed = keyValue.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                var valueExists = false
                for key in updated.keys {
                    if let stored = keychainLoad(key: key.id.uuidString), stored == trimmed {
                        valueExists = true; break
                    }
                }
                if !valueExists {
                    let resolvedName = resolveKeyName(keyName, existingKeys: updated.keys)
                    let newKey = APIKey(name: resolvedName)
                    saveApiKey(trimmed, for: newKey.id)
                    updated.keys.append(newKey)
                }
            }
        }

        let newModels = buildModels(from: remote, selectedIds: selectedModelIds)
        let existingIds = Set(updated.models.map { $0.id })
        updated.models.append(contentsOf: newModels.filter { !existingIds.contains($0.id) })

        try await persistProvider(updated)
        try await refreshCache()

        print("[AIProviderStore] Merged into catalog provider '\(updated.displayName)'")
        return updated.id
    }

    // MARK: - Merge Provider (Onboarding)

    @discardableResult
    public func mergeProvider(
        _ incoming: AIProvider,
        keyName: String,
        keyValue: String,
        models: [AIModel]
    ) async throws -> UUID {
        let existing = try await getProviders()
        let incomingHost = URL(string: incoming.baseURL)?.host ?? incoming.baseURL

        if var matched = existing.first(where: { provider in
            (URL(string: provider.baseURL)?.host ?? provider.baseURL) == incomingHost
        }) {
            if !incoming.name.isEmpty { matched.name = incoming.name }

            let trimmedValue = keyValue.trimmingCharacters(in: .whitespaces)
            if !trimmedValue.isEmpty {
                var valueExists = false
                for existingKey in matched.keys {
                    if let stored = keychainLoad(key: existingKey.id.uuidString), stored == trimmedValue {
                        var updatedKey = existingKey
                        if !keyName.isEmpty { updatedKey.name = keyName }
                        if let idx = matched.keys.firstIndex(where: { $0.id == existingKey.id }) {
                            matched.keys[idx] = updatedKey
                        }
                        valueExists = true; break
                    }
                }
                if !valueExists {
                    let resolvedName = resolveKeyName(keyName, existingKeys: matched.keys)
                    let newKey = APIKey(name: resolvedName)
                    saveApiKey(trimmedValue, for: newKey.id)
                    matched.keys.append(newKey)
                }
            }

            let existingModelIds = Set(matched.models.map { $0.id })
            matched.models.append(contentsOf: models.filter { !existingModelIds.contains($0.id) })

            try await persistProvider(matched)
            try await refreshCache()
            print("[AIProviderStore] Merged provider '\(matched.displayName)'")
            return matched.id

        } else {
            let id = try await addProvider(incoming, firstKeyName: keyName, firstKeyValue: keyValue)
            if var newProvider = try await getProviders().first(where: { $0.id == id }) {
                newProvider.models = models
                try await persistProvider(newProvider)
                try await refreshCache()
            }
            return id
        }
    }

    // MARK: - Sync from Remote Catalog

    public func syncRequiresApiKey(from remoteProviders: [RemoteProvider]) async throws {
        var providers = try await getProviders()
        var changed = false

        for remote in remoteProviders {
            guard let idx = providers.firstIndex(where: { $0.catalogId == remote.id }) else { continue }
            guard providers[idx].requiresApiKey != remote.requiresApiKey else { continue }
            providers[idx].requiresApiKey = remote.requiresApiKey
            changed = true
        }

        if changed {
            try await saveProviders(providers)
            try await refreshCache()
        }
    }

    public func syncIcons(from remoteProviders: [RemoteProvider]) async throws {
        var providers = try await getProviders()
        var changed = false

        for remote in remoteProviders {
            guard let idx = providers.firstIndex(where: { $0.catalogId == remote.id }) else { continue }
            let iconChanged = providers[idx].iconName != remote.iconName
            let colorChanged = providers[idx].iconColor != remote.iconColor
            guard iconChanged || colorChanged else { continue }
            providers[idx].iconName = remote.iconName
            providers[idx].iconColor = remote.iconColor
            changed = true
        }

        if changed {
            try await saveProviders(providers)
            try await refreshCache()
        }
    }

    // MARK: - Private Helpers

    func buildModels(from remote: RemoteProvider, selectedIds: Set<String>?) -> [AIModel] {
        remote.models
            .filter { selectedIds == nil || selectedIds!.contains($0.id) }
            .map { rm in
                AIModel(
                    id: rm.id,
                    name: rm.name,
                    endpoint: rm.endpoint,
                    providerProtocol: rm.protocol == "anthropic" ? .anthropic : .openai
                )
            }
    }

    func dominantProtocol(in remote: RemoteProvider) -> ProviderProtocol {
        let anthropicCount = remote.models.filter { $0.protocol == "anthropic" }.count
        return anthropicCount > remote.models.count / 2 ? .anthropic : .openai
    }
}
