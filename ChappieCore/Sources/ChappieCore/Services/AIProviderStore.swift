// AIProviderStore.swift
// ChappieCore
//
// CRUD service for AI providers via ChappieDataStore. Keychain for API keys.
// No SwiftData imports here — all persistence goes through ChappieDataStore.Relation.providers.
//
// STORAGE LAYOUT:
// All providers stored as [AIProvider] under Relation.providers.
// API key secrets live exclusively in Keychain, keyed by apiKey.id.uuidString.
//
// CACHING:
// cachedProviders holds the full list in RAM after first load.
// All reads return from cache. All writes call refreshCache() after saving.
//
// CODABLE COMPATIBILITY (see DataStore.swift for full rules):
//   AIProvider already has CodingKeys — safe to evolve without breaking stored records.
//   Never remove fields — mark optional with a default instead.
//   New fields must have a default value so old records decode cleanly.

import Foundation
import Security

// MARK: - AIProviderStore

public actor AIProviderStore {

    // MARK: - Dependencies

    private let dataStore: ChappieDataStore

    // MARK: - In-memory cache

    private var cachedProviders: [AIProvider]? = nil
    private var cachedDefaultId: UUID? = nil

    // MARK: - Keychain constants

    private let keychainService: String = {
        Bundle.main.bundleIdentifier ?? "ru.chappie"
    }()

    // MARK: - Init

    public init(dataStore: ChappieDataStore) {
        self.dataStore = dataStore
    }

    // MARK: - Cache Management

    private func refreshCache() async throws {
        let providers: [AIProvider] = (try await dataStore.load(.providers)) ?? []
        cachedProviders = providers
        // Default is the first provider marked isDefault, or the oldest one
        // WHY: isDefault is a property on AIProvider — we track it in the array itself
        cachedDefaultId = providers.first(where: { $0.isDefault })?.id ?? providers.first?.id
    }

    private func getProviders() async throws -> [AIProvider] {
        if let cached = cachedProviders { return cached }
        try await refreshCache()
        return cachedProviders ?? []
    }

    private func saveProviders(_ providers: [AIProvider]) async throws {
        try await dataStore.save(providers, for: .providers)
    }

    // MARK: - Load

    /// Returns all stored providers, sorted by creation date (oldest first).
    /// Runs single-key migration for providers that predate the multi-key schema.
    public func loadProviders() async throws -> [AIProvider] {
        var providers = try await getProviders()
        var needsRefresh = false

        for i in providers.indices where providers[i].keys.isEmpty && providers[i].requiresApiKey {
            if let secret = keychainLoad(key: providers[i].id.uuidString), !secret.isEmpty {
                let newKey = APIKey(name: "Default")
                saveApiKey(secret, for: newKey.id)
                deleteKeychainEntry(key: providers[i].id.uuidString)
                providers[i].keys = [newKey]
                needsRefresh = true
                print("[AIProviderStore] Migrated single key for provider '\(providers[i].displayName)'")
            }
        }

        if needsRefresh {
            try await saveProviders(providers)
            try await refreshCache()
        }

        return try await getProviders()
    }

    public func loadDefaultProvider() async throws -> AIProvider? {
        let providers = try await getProviders()
        if let defaultId = cachedDefaultId,
           let found = providers.first(where: { $0.id == defaultId }) {
            return found
        }
        return providers.first
    }

    public func loadProvider(id: UUID) async throws -> AIProvider? {
        return try await getProviders().first(where: { $0.id == id })
    }

    // MARK: - Sync from catalog

    public func syncRequiresApiKey(from remoteProviders: [RemoteProvider]) async throws {
        var providers = try await getProviders()
        var changed = false

        for remote in remoteProviders {
            guard let idx = providers.firstIndex(where: { $0.catalogId == remote.id }) else { continue }
            guard providers[idx].requiresApiKey != remote.requiresApiKey else { continue }
            providers[idx].requiresApiKey = remote.requiresApiKey
            changed = true
            print("[AIProviderStore] Synced requiresApiKey=\(remote.requiresApiKey) for '\(providers[idx].displayName)'")
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
            print("[AIProviderStore] Synced icon '\(remote.iconName)' for '\(providers[idx].displayName)'")
        }

        if changed {
            try await saveProviders(providers)
            try await refreshCache()
        }
    }

    // MARK: - Add Provider (Custom / Manual)

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

        // First provider becomes default
        if providers.isEmpty {
            providerWithKey.isDefault = true
        }

        providers.append(providerWithKey)
        try await saveProviders(providers)
        try await refreshCache()

        print("[AIProviderStore] Added provider '\(providerWithKey.displayName)'")
        return providerWithKey.id
    }

    // MARK: - Add Provider from Catalog

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

    // MARK: - Duplicate Check Helpers

    public func providerHostExists(_ baseURL: String) async -> Bool {
        let host = URL(string: baseURL)?.host ?? baseURL
        return (try? await getProviders().contains(where: { provider in
            (URL(string: provider.baseURL)?.host ?? provider.baseURL) == host
        })) ?? false
    }

    public func providerCatalogIdExists(_ catalogId: String) async -> Bool {
        return (try? await getProviders().contains(where: { $0.catalogId == catalogId })) ?? false
    }

    public func keyValueExists(_ value: String, inProviderId providerId: UUID) async -> Bool {
        guard let provider = (try? await getProviders().first(where: { $0.id == providerId })) else {
            return false
        }
        for key in provider.keys {
            if let stored = keychainLoad(key: key.id.uuidString), stored == value { return true }
        }
        return false
    }

    // MARK: - Update Provider

    public func updateProvider(_ provider: AIProvider) async throws {
        try await persistProvider(provider)
        try await refreshCache()
        print("[AIProviderStore] Updated provider '\(provider.displayName)'")
    }

    // MARK: - Delete Provider

    public func deleteProvider(id: UUID) async throws {
        var providers = try await getProviders()
        guard let idx = providers.firstIndex(where: { $0.id == id }) else {
            throw AIProviderStoreError.notFound(id)
        }

        let wasDefault = providers[idx].isDefault
        for key in providers[idx].keys { deleteKeychainEntry(key: key.id.uuidString) }
        providers.remove(at: idx)

        // Reassign default if needed
        if wasDefault, let first = providers.first {
            providers[0].isDefault = true
            _ = first // silence warning
        }

        try await saveProviders(providers)
        try await refreshCache()
        print("[AIProviderStore] Deleted provider id: \(id)")
    }

    // MARK: - Key Management

    @discardableResult
    public func addKey(
        name: String,
        value: String,
        toProviderId providerId: UUID
    ) async throws -> APIKey {
        var providers = try await getProviders()
        guard let idx = providers.firstIndex(where: { $0.id == providerId }) else {
            throw AIProviderStoreError.notFound(providerId)
        }

        let newKey = APIKey(name: name.isEmpty ? "Key \(providers[idx].keys.count + 1)" : name)
        saveApiKey(value, for: newKey.id)
        providers[idx].keys.append(newKey)

        try await saveProviders(providers)
        try await refreshCache()
        print("[AIProviderStore] Added key '\(newKey.name)' to provider '\(providers[idx].displayName)'")
        return newKey
    }

    public func updateKey(
        _ key: APIKey,
        newValue: String?,
        forProviderId providerId: UUID
    ) async throws {
        var providers = try await getProviders()
        guard let pIdx = providers.firstIndex(where: { $0.id == providerId }) else {
            throw AIProviderStoreError.notFound(providerId)
        }
        guard let kIdx = providers[pIdx].keys.firstIndex(where: { $0.id == key.id }) else {
            throw AIProviderStoreError.keyNotFound(key.id)
        }

        providers[pIdx].keys[kIdx] = key
        if let value = newValue, !value.isEmpty { saveApiKey(value, for: key.id) }

        try await saveProviders(providers)
        try await refreshCache()
        print("[AIProviderStore] Updated key '\(key.name)'")
    }

    public func deleteKey(id keyId: UUID, fromProviderId providerId: UUID) async throws {
        var providers = try await getProviders()
        guard let idx = providers.firstIndex(where: { $0.id == providerId }) else {
            throw AIProviderStoreError.notFound(providerId)
        }

        providers[idx].keys.removeAll { $0.id == keyId }
        deleteKeychainEntry(key: keyId.uuidString)

        try await saveProviders(providers)
        try await refreshCache()
        print("[AIProviderStore] Deleted key \(keyId)")
    }

    // MARK: - Model Management

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
        print("[AIProviderStore] Added model '\(model.id)' to provider '\(providers[idx].displayName)'")
    }

    public func deleteModel(id modelId: String, fromProviderId providerId: UUID) async throws {
        var providers = try await getProviders()
        guard let idx = providers.firstIndex(where: { $0.id == providerId }) else {
            throw AIProviderStoreError.notFound(providerId)
        }

        providers[idx].models.removeAll { $0.id == modelId }
        try await saveProviders(providers)
        try await refreshCache()
        print("[AIProviderStore] Deleted model '\(modelId)'")
    }

    // MARK: - Default

    public func setDefault(id: UUID) async throws {
        var providers = try await getProviders()
        for i in providers.indices { providers[i].isDefault = (providers[i].id == id) }
        try await saveProviders(providers)
        try await refreshCache()
        print("[AIProviderStore] Default provider set to id: \(id)")
    }

    // MARK: - API Key (Keychain)

    public func loadApiKey(for keyId: UUID) -> String? {
        return keychainLoad(key: keyId.uuidString)
    }

    public func hasProviders() async -> Bool {
        return (try? await getProviders().isEmpty == false) ?? false
    }

    // MARK: - Private Helpers

    private func persistProvider(_ provider: AIProvider) async throws {
        var providers = try await getProviders()
        guard let idx = providers.firstIndex(where: { $0.id == provider.id }) else {
            throw AIProviderStoreError.notFound(provider.id)
        }
        providers[idx] = provider
        try await saveProviders(providers)
    }

    private func resolveKeyName(_ name: String, existingKeys: [APIKey]) -> String {
        let base = name.isEmpty ? "Key" : name
        guard existingKeys.contains(where: { $0.name.lowercased() == base.lowercased() }) else {
            return base
        }
        var suffix = 2
        while existingKeys.contains(where: {
            $0.name.lowercased() == "\(base) \(suffix)".lowercased()
        }) { suffix += 1 }
        return "\(base) \(suffix)"
    }

    private func buildModels(from remote: RemoteProvider, selectedIds: Set<String>?) -> [AIModel] {
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

    private func dominantProtocol(in remote: RemoteProvider) -> ProviderProtocol {
        let anthropicCount = remote.models.filter { $0.protocol == "anthropic" }.count
        return anthropicCount > remote.models.count / 2 ? .anthropic : .openai
    }

    // MARK: - Keychain Helpers

    private func saveApiKey(_ value: String, for keyId: UUID) {
        guard let data = value.data(using: .utf8) else { return }
        let key = keyId.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: keychainService
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func keychainLoad(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    private func deleteKeychainEntry(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: keychainService
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - AIProviderStoreError

public enum AIProviderStoreError: LocalizedError {
    case notFound(UUID)
    case keyNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): return "Provider not found: \(id)"
        case .keyNotFound(let id): return "API key not found: \(id)"
        }
    }
}
