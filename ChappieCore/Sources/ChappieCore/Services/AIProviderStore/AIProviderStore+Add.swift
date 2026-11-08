// AIProviderStore+Add.swift
// ChappieCore
//
// Add provider + onboarding merge flow.

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
}
