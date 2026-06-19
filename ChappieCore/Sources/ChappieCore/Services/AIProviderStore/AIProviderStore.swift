// AIProviderStore.swift
// ChappieCore
//
// Core: init, cache, load, update, delete, default management.

import Foundation
import Security

// MARK: - AIProviderStore

public actor AIProviderStore {

    let dataStore: any ChappieStorage
    var cachedProviders: [AIProvider]? = nil
    var cachedDefaultId: UUID? = nil

    let keychainService: String = {
        Bundle.main.bundleIdentifier ?? "ru.chappie"
    }()

    public init(dataStore: any ChappieStorage) {
        self.dataStore = dataStore
    }

    // MARK: - Cache

    func refreshCache() async throws {
        let providers: [AIProvider] = (try await dataStore.load(.providers)) ?? []
        cachedProviders = providers
        cachedDefaultId = providers.first(where: { $0.isDefault })?.id ?? providers.first?.id
    }

    func getProviders() async throws -> [AIProvider] {
        if let cached = cachedProviders { return cached }
        try await refreshCache()
        return cachedProviders ?? []
    }

    func saveProviders(_ providers: [AIProvider]) async throws {
        try await dataStore.save(providers, for: .providers)
    }

    // MARK: - Load

    /// Returns all stored providers. Runs single-key migration for pre-multi-key records.
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

    // MARK: - Update / Delete

    public func updateProvider(_ provider: AIProvider) async throws {
        try await persistProvider(provider)
        try await refreshCache()
    }

    public func deleteProvider(id: UUID) async throws {
        var providers = try await getProviders()
        guard let idx = providers.firstIndex(where: { $0.id == id }) else {
            throw AIProviderStoreError.notFound(id)
        }

        let wasDefault = providers[idx].isDefault
        for key in providers[idx].keys { deleteKeychainEntry(key: key.id.uuidString) }
        providers.remove(at: idx)

        if wasDefault, !providers.isEmpty { providers[0].isDefault = true }

        try await saveProviders(providers)
        try await refreshCache()
        print("[AIProviderStore] Deleted provider id: \(id)")
    }

    // MARK: - Default

    public func setDefault(id: UUID) async throws {
        var providers = try await getProviders()
        for i in providers.indices { providers[i].isDefault = (providers[i].id == id) }
        try await saveProviders(providers)
        try await refreshCache()
    }

    public func hasProviders() async -> Bool {
        return (try? await getProviders().isEmpty == false) ?? false
    }

    // MARK: - Duplicate Checks

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

    // MARK: - Internal Helpers

    func persistProvider(_ provider: AIProvider) async throws {
        var providers = try await getProviders()
        guard let idx = providers.firstIndex(where: { $0.id == provider.id }) else {
            throw AIProviderStoreError.notFound(provider.id)
        }
        providers[idx] = provider
        try await saveProviders(providers)
    }

    func resolveKeyName(_ name: String, existingKeys: [APIKey]) -> String {
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
