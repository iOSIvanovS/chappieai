// AIProviderStore.swift
// ChappieCore
//
// CRUD service for AI providers — SwiftData backend, Keychain for API keys.
//
// ARCHITECTURE:
// - AIProviderEntity in SwiftData stores provider config as JSON (no graph pattern)
// - API key secrets live exclusively in Keychain, keyed by apiKey.id.uuidString
// - Each provider can have multiple named APIKey entries (multi-key schema)
//
// CATALOG FLOW:
// addFromCatalog() — creates a provider from a RemoteProvider entry.
//   Converts RemoteModel → AIModel, preserving endpoint + protocol per model.
//   Duplicate check: by catalogId. If already exists → mergeFromCatalog() instead.
//   requiresApiKey is copied from RemoteProvider — false for Ollama.
//
// CUSTOM FLOW:
// addProvider() — creates a provider entered manually (catalogId = nil).
//   No duplicate check for custom providers (origin = .custom).
//
// DELETION POLICY:
// Deletion is ALWAYS allowed — even the last provider, even if threads depend on it.
// Orphaned threads show a warning banner. No blocking guards here.
//
// THREAD SAFETY:
// All async methods run in a detached Task with ModelContainer actor isolation.
//
// CACHING:
// cachedProviders holds the full list in RAM after first load.
// All reads return from cache. All writes call refreshCache() after saving.
//
// DEFAULT PROVIDER:
// isDefault lives on AIProviderEntity. cachedDefaultId answers loadDefaultProvider()
// without iterating JSON or hitting the DB.

import Foundation
import SwiftData
import Security

// MARK: - AIProviderStore

public actor AIProviderStore {

    // MARK: - Dependencies

    private let modelContainer: ModelContainer

    // MARK: - In-memory cache

    private var cachedProviders: [AIProvider]? = nil
    private var cachedDefaultId: UUID? = nil

    // MARK: - Keychain constants

    private let keychainService: String = {
        Bundle.main.bundleIdentifier ?? "ru.chappie"
    }()

    // MARK: - Init

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Cache Management

    private func refreshCache() throws {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<AIProviderEntity>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let entities = try context.fetch(descriptor)
        cachedProviders = entities.compactMap { $0.toProvider() }
        cachedDefaultId = entities.first(where: { $0.isDefault })?.id
    }

    private func getProviders() throws -> [AIProvider] {
        if let cached = cachedProviders { return cached }
        try refreshCache()
        return cachedProviders ?? []
    }

    // MARK: - Load

    /// Returns all stored providers, sorted by creation date (oldest first).
    /// Runs single-key migration for providers that predate the multi-key schema.
    public func loadProviders() async throws -> [AIProvider] {
        var providers = try getProviders()
        var needsRefresh = false

        for i in providers.indices where providers[i].keys.isEmpty && providers[i].requiresApiKey {
            // Old schema: secret stored under provider.id.uuidString — migrate it
            if let secret = keychainLoad(key: providers[i].id.uuidString), !secret.isEmpty {
                let newKey = APIKey(name: "Default")
                saveApiKey(secret, for: newKey.id)
                deleteKeychainEntry(key: providers[i].id.uuidString)
                providers[i].keys = [newKey]
                try persistProvider(providers[i])
                needsRefresh = true
                print("[AIProviderStore] Migrated single key for provider '\(providers[i].displayName)'")
            }
        }

        if needsRefresh { try refreshCache() }
        return try getProviders()
    }

    public func loadDefaultProvider() async throws -> AIProvider? {
        let providers = try getProviders()
        if let defaultId = cachedDefaultId,
           let found = providers.first(where: { $0.id == defaultId }) {
            return found
        }
        return providers.first
    }

    public func loadProvider(id: UUID) async throws -> AIProvider? {
        return try getProviders().first(where: { $0.id == id })
    }

    // MARK: - Sync requiresApiKey from catalog

    /// Called at startup after the remote catalog is fetched.
    /// Updates requiresApiKey for existing catalog providers whose value changed in the JSON.
    public func syncRequiresApiKey(from remoteProviders: [RemoteProvider]) async throws {
        let existing = try getProviders()
        var changed = false

        for remote in remoteProviders {
            guard let idx = existing.firstIndex(where: { $0.catalogId == remote.id }) else { continue }
            var provider = existing[idx]
            guard provider.requiresApiKey != remote.requiresApiKey else { continue }

            provider.requiresApiKey = remote.requiresApiKey
            try persistProvider(provider)
            changed = true
            print("[AIProviderStore] Synced requiresApiKey=\(remote.requiresApiKey) for '\(provider.displayName)'")
        }

        if changed { try refreshCache() }
    }

    // MARK: - Sync icons from catalog

    /// Called at startup after the remote catalog is fetched.
    /// Updates iconName + iconColor for existing catalog providers.
    /// Safe to call every launch — only writes when value actually changed.
    public func syncIcons(from remoteProviders: [RemoteProvider]) async throws {
        let existing = try getProviders()
        var changed = false

        for remote in remoteProviders {
            guard let idx = existing.firstIndex(where: { $0.catalogId == remote.id }) else { continue }
            var provider = existing[idx]

            let iconChanged = provider.iconName != remote.iconName
            let colorChanged = provider.iconColor != remote.iconColor
            guard iconChanged || colorChanged else { continue }

            provider.iconName = remote.iconName
            provider.iconColor = remote.iconColor
            try persistProvider(provider)
            changed = true
            print("[AIProviderStore] Synced icon '\(remote.iconName)' for '\(provider.displayName)'")
        }

        if changed { try refreshCache() }
    }

    // MARK: - Add Provider (Custom / Manual)

    /// Adds a manually-entered provider (origin = .custom).
    /// No duplicate check — custom providers are always created freely.
    @discardableResult
    public func addProvider(
        _ provider: AIProvider,
        firstKeyName: String,
        firstKeyValue: String
    ) async throws -> UUID {
        let context = ModelContext(modelContainer)

        var providerWithKey = provider

        // Only add key if provider requires one
        if provider.requiresApiKey {
            let firstKey = APIKey(name: firstKeyName.isEmpty ? "Default" : firstKeyName)
            saveApiKey(firstKeyValue, for: firstKey.id)
            providerWithKey.keys = [firstKey]
        }

        let entity = AIProviderEntity(provider: providerWithKey, isDefault: false)

        let existingCount = (try? context.fetch(FetchDescriptor<AIProviderEntity>()).count) ?? 0
        if existingCount == 0 { entity.isDefault = true }

        context.insert(entity)
        try context.save()
        try refreshCache()

        print("[AIProviderStore] Added provider '\(providerWithKey.displayName)'")
        return providerWithKey.id
    }

    // MARK: - Add Provider from Catalog

    /// Creates a new provider from a RemoteProvider catalog entry.
    /// Converts all RemoteModel entries to AIModel (preserving endpoint + protocol).
    /// If a provider with the same catalogId already exists — merges instead.
    /// requiresApiKey is copied from RemoteProvider (false for Ollama).
    ///
    /// Returns the UUID of the created or updated provider.
    @discardableResult
    public func addFromCatalog(
        _ remote: RemoteProvider,
        keyName: String,
        keyValue: String,
        selectedModelIds: Set<String>? = nil  // nil = all models
    ) async throws -> UUID {
        let existing = try getProviders()

        // If provider with same catalogId exists — merge key and models
        if let matched = existing.first(where: { $0.catalogId == remote.id }) {
            return try await mergeIntoCatalogProvider(
                matched,
                remote: remote,
                keyName: keyName,
                keyValue: keyValue,
                selectedModelIds: selectedModelIds
            )
        }

        // Build AIModel list from remote catalog
        let allModels = buildModels(from: remote, selectedIds: selectedModelIds)

        // Create the provider — copy requiresApiKey + icon from catalog entry
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

    /// Merges a new key and models into an existing catalog provider.
    private func mergeIntoCatalogProvider(
        _ existing: AIProvider,
        remote: RemoteProvider,
        keyName: String,
        keyValue: String,
        selectedModelIds: Set<String>?
    ) async throws -> UUID {
        var updated = existing

        // Merge key — skip if same value already present or provider doesn't need one
        if remote.requiresApiKey {
            let trimmed = keyValue.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                var valueExists = false
                for key in updated.keys {
                    if let stored = keychainLoad(key: key.id.uuidString), stored == trimmed {
                        valueExists = true
                        break
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

        // Merge models — add only those not already present (by id)
        let newModels = buildModels(from: remote, selectedIds: selectedModelIds)
        let existingIds = Set(updated.models.map { $0.id })
        let toAdd = newModels.filter { !existingIds.contains($0.id) }
        updated.models.append(contentsOf: toAdd)

        try persistProvider(updated)
        try refreshCache()

        print("[AIProviderStore] Merged into catalog provider '\(updated.displayName)'")
        return updated.id
    }

    // MARK: - Merge Provider (Onboarding — legacy host-based)

    /// Onboarding upsert — matches by baseURL host. Safe to call multiple times.
    @discardableResult
    public func mergeProvider(
        _ incoming: AIProvider,
        keyName: String,
        keyValue: String,
        models: [AIModel]
    ) async throws -> UUID {
        let existing = try getProviders()
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
                        valueExists = true
                        break
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
            let newModels = models.filter { !existingModelIds.contains($0.id) }
            matched.models.append(contentsOf: newModels)

            try persistProvider(matched)
            try refreshCache()
            print("[AIProviderStore] Merged provider '\(matched.displayName)' (host: \(incomingHost))")
            return matched.id

        } else {
            let id = try await addProvider(incoming, firstKeyName: keyName, firstKeyValue: keyValue)
            if var newProvider = try getProviders().first(where: { $0.id == id }) {
                newProvider.models = models
                try persistProvider(newProvider)
                try refreshCache()
            }
            return id
        }
    }

    // MARK: - Duplicate Check Helpers

    /// True if a provider with the same host already exists (for custom add flow).
    public func providerHostExists(_ baseURL: String) async -> Bool {
        let host = URL(string: baseURL)?.host ?? baseURL
        return (try? getProviders().contains(where: { provider in
            (URL(string: provider.baseURL)?.host ?? provider.baseURL) == host
        })) ?? false
    }

    /// True if a provider with the given catalogId already exists.
    public func providerCatalogIdExists(_ catalogId: String) async -> Bool {
        return (try? getProviders().contains(where: { $0.catalogId == catalogId })) ?? false
    }

    /// True if a key with the same value already exists for the given provider.
    public func keyValueExists(_ value: String, inProviderId providerId: UUID) async -> Bool {
        guard let provider = (try? getProviders().first(where: { $0.id == providerId })) else {
            return false
        }
        for key in provider.keys {
            if let stored = keychainLoad(key: key.id.uuidString), stored == value {
                return true
            }
        }
        return false
    }

    // MARK: - Update Provider

    public func updateProvider(_ provider: AIProvider) async throws {
        try persistProvider(provider)
        try refreshCache()
        print("[AIProviderStore] Updated provider '\(provider.displayName)'")
    }

    // MARK: - Delete Provider

    public func deleteProvider(id: UUID) async throws {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<AIProviderEntity>(
            predicate: #Predicate { $0.id == id }
        )
        guard let entity = try context.fetch(descriptor).first else {
            throw AIProviderStoreError.notFound(id)
        }

        if let provider = entity.toProvider() {
            for key in provider.keys { deleteKeychainEntry(key: key.id.uuidString) }
        }

        let wasDefault = entity.isDefault
        context.delete(entity)
        try context.save()

        if wasDefault {
            let remaining = try context.fetch(FetchDescriptor<AIProviderEntity>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            ))
            if let first = remaining.first {
                first.isDefault = true
                try context.save()
            }
        }

        try refreshCache()
        print("[AIProviderStore] Deleted provider id: \(id)")
    }

    // MARK: - Key Management

    @discardableResult
    public func addKey(
        name: String,
        value: String,
        toProviderId providerId: UUID
    ) async throws -> APIKey {
        guard var provider = try getProviders().first(where: { $0.id == providerId }) else {
            throw AIProviderStoreError.notFound(providerId)
        }

        let newKey = APIKey(name: name.isEmpty ? "Key \(provider.keys.count + 1)" : name)
        saveApiKey(value, for: newKey.id)
        provider.keys.append(newKey)

        try persistProvider(provider)
        try refreshCache()
        print("[AIProviderStore] Added key '\(newKey.name)' to provider '\(provider.displayName)'")
        return newKey
    }

    public func updateKey(
        _ key: APIKey,
        newValue: String?,
        forProviderId providerId: UUID
    ) async throws {
        guard var provider = try getProviders().first(where: { $0.id == providerId }) else {
            throw AIProviderStoreError.notFound(providerId)
        }
        guard let idx = provider.keys.firstIndex(where: { $0.id == key.id }) else {
            throw AIProviderStoreError.keyNotFound(key.id)
        }

        provider.keys[idx] = key
        if let value = newValue, !value.isEmpty { saveApiKey(value, for: key.id) }

        try persistProvider(provider)
        try refreshCache()
        print("[AIProviderStore] Updated key '\(key.name)' on provider '\(provider.displayName)'")
    }

    public func deleteKey(id keyId: UUID, fromProviderId providerId: UUID) async throws {
        guard var provider = try getProviders().first(where: { $0.id == providerId }) else {
            throw AIProviderStoreError.notFound(providerId)
        }

        provider.keys.removeAll { $0.id == keyId }
        deleteKeychainEntry(key: keyId.uuidString)

        try persistProvider(provider)
        try refreshCache()
        print("[AIProviderStore] Deleted key \(keyId) from provider '\(provider.displayName)'")
    }

    // MARK: - Model Management

    public func addModel(_ model: AIModel, toProviderId providerId: UUID) async throws {
        guard var provider = try getProviders().first(where: { $0.id == providerId }) else {
            throw AIProviderStoreError.notFound(providerId)
        }

        guard !model.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !provider.models.contains(where: { $0.id == model.id }) else { return }

        provider.models.append(model)
        try persistProvider(provider)
        try refreshCache()
        print("[AIProviderStore] Added model '\(model.id)' to provider '\(provider.displayName)'")
    }

    public func deleteModel(id modelId: String, fromProviderId providerId: UUID) async throws {
        guard var provider = try getProviders().first(where: { $0.id == providerId }) else {
            throw AIProviderStoreError.notFound(providerId)
        }

        provider.models.removeAll { $0.id == modelId }
        try persistProvider(provider)
        try refreshCache()
        print("[AIProviderStore] Deleted model '\(modelId)' from provider '\(provider.displayName)'")
    }

    // MARK: - Default

    public func setDefault(id: UUID) async throws {
        let context = ModelContext(modelContainer)
        let allEntities = try context.fetch(FetchDescriptor<AIProviderEntity>())
        for entity in allEntities { entity.isDefault = (entity.id == id) }
        try context.save()
        try refreshCache()
        print("[AIProviderStore] Default provider set to id: \(id)")
    }

    // MARK: - API Key (Keychain)

    public func loadApiKey(for keyId: UUID) -> String? {
        return keychainLoad(key: keyId.uuidString)
    }

    public func hasProviders() async -> Bool {
        return (try? getProviders().isEmpty == false) ?? false
    }

    // MARK: - Private Helpers

    private func persistProvider(_ provider: AIProvider) throws {
        let context = ModelContext(modelContainer)
        let id = provider.id
        let descriptor = FetchDescriptor<AIProviderEntity>(
            predicate: #Predicate { $0.id == id }
        )
        guard let entity = try context.fetch(descriptor).first else {
            throw AIProviderStoreError.notFound(provider.id)
        }
        entity.update(from: provider)
        try context.save()
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

    /// Builds AIModel list from a RemoteProvider, optionally filtering by selected IDs.
    private func buildModels(
        from remote: RemoteProvider,
        selectedIds: Set<String>?
    ) -> [AIModel] {
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

    /// Returns the most common protocol among models — used as the provider-level default.
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
