// AIProviderStore.swift
// ChappieCore
//
// CRUD service for AI providers — SwiftData backend, Keychain for API keys.
//
// ARCHITECTURE:
// - AIProviderEntity in SwiftData stores provider config as JSON (no graph pattern)
// - API key secrets live exclusively in Keychain, keyed by apiKey.id.uuidString
// - Each provider can have multiple named APIKey entries (multi-key schema)
// - This class is the single source of truth for provider management
//
// MIGRATION FROM SINGLE-KEY SCHEMA:
// Old schema stored one secret per provider under provider.id.uuidString in Keychain.
// On first load, providers with empty keys[] are detected and migrated automatically:
//   1. Read old secret from Keychain using provider.id.uuidString
//   2. Create a new APIKey(name: "Default") with a fresh UUID
//   3. Store secret in Keychain under apiKey.id.uuidString
//   4. Delete old Keychain entry under provider.id.uuidString
//   5. Persist updated AIProvider JSON to SwiftData
//
// DELETION POLICY:
// Deletion is ALWAYS allowed — even the last provider, even if threads depend on it.
// Orphaned threads (provider or model or key missing) show a warning banner in the chat view.
// No blocking guards here — freedom to the user, smart warnings in the UI.
//
// THREAD SAFETY:
// All async methods run in a detached Task with ModelContainer actor isolation.
// Same pattern as ThreadStore and ProjectStore.
//
// CACHING:
// cachedProviders holds the full list in RAM after first load.
// All reads return from cache — zero SwiftData hits on hot path.
// All writes invalidate the cache by calling refreshCache() after saving.
//
// DEFAULT PROVIDER:
// isDefault lives on AIProviderEntity (SwiftData), not on AIProvider (domain model).
// The cache stores a separate cachedDefaultId to answer loadDefaultProvider() without
// iterating over JSON or hitting the DB.

import Foundation
import SwiftData
import Security

// MARK: - AIProviderStore

/// Manages persistence of AI providers using SwiftData + Keychain.
///
/// USAGE:
/// - loadProviders() → [AIProvider]
/// - addProvider(_ provider:, firstKeyName:, firstKeyValue:) → UUID
/// - updateProvider(_ provider:)
/// - deleteProvider(id:)
/// - addKey(name:value:toProviderId:) → APIKey
/// - updateKey(_ key:, newValue:, forProviderId:)
/// - deleteKey(id:fromProviderId:)
/// - addModel(_ modelName:, toProviderId:)
/// - deleteModel(_ modelName:, fromProviderId:)
/// - setDefault(id:)
/// - loadDefaultProvider() → AIProvider?
/// - loadApiKey(for keyId:) → String?
public actor AIProviderStore {

    // MARK: - Dependencies

    private let modelContainer: ModelContainer

    // MARK: - In-memory cache

    // Full provider list — populated on first access, invalidated on writes.
    private var cachedProviders: [AIProvider]? = nil
    // ID of the default provider — kept in sync with cachedProviders.
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

    /// Loads all providers from SwiftData and stores them in cachedProviders.
    /// Called after every write operation to keep cache fresh.
    private func refreshCache() throws {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<AIProviderEntity>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let entities = try context.fetch(descriptor)
        cachedProviders = entities.compactMap { $0.toProvider() }
        cachedDefaultId = entities.first(where: { $0.isDefault })?.id
    }

    /// Returns cached providers, loading from SwiftData on first call.
    private func getProviders() throws -> [AIProvider] {
        if let cached = cachedProviders { return cached }
        try refreshCache()
        return cachedProviders ?? []
    }

    // MARK: - Load

    /// Returns all stored providers, sorted by creation date (oldest first).
    /// Served from in-memory cache — no SwiftData hit on warm calls.
    /// Runs single-key migration on providers that predate the multi-key schema.
    public func loadProviders() async throws -> [AIProvider] {
        var providers = try getProviders()
        var needsRefresh = false

        for i in providers.indices where providers[i].keys.isEmpty {
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

    /// Returns the default provider, or the first one if no default is set.
    public func loadDefaultProvider() async throws -> AIProvider? {
        let providers = try getProviders()
        if let defaultId = cachedDefaultId,
           let found = providers.first(where: { $0.id == defaultId }) {
            return found
        }
        return providers.first
    }

    /// Returns a single provider by ID.
    public func loadProvider(id: UUID) async throws -> AIProvider? {
        return try getProviders().first(where: { $0.id == id })
    }

    // MARK: - Add Provider

    /// Persists a new provider with its first API key.
    /// Returns the new provider's UUID.
    @discardableResult
    public func addProvider(
        _ provider: AIProvider,
        firstKeyName: String,
        firstKeyValue: String
    ) async throws -> UUID {
        let context = ModelContext(modelContainer)

        // Create the first APIKey and store its secret in Keychain
        let firstKey = APIKey(name: firstKeyName.isEmpty ? "Default" : firstKeyName)
        saveApiKey(firstKeyValue, for: firstKey.id)

        var providerWithKey = provider
        providerWithKey.keys = [firstKey]

        let entity = AIProviderEntity(provider: providerWithKey, isDefault: false)

        // First provider ever — make it default automatically
        let existingCount = (try? context.fetch(FetchDescriptor<AIProviderEntity>()).count) ?? 0
        if existingCount == 0 {
            entity.isDefault = true
        }

        context.insert(entity)
        try context.save()

        try refreshCache()

        print("[AIProviderStore] Added provider '\(providerWithKey.displayName)' with key '\(firstKey.name)'")
        return providerWithKey.id
    }

    // MARK: - Update Provider

    /// Updates an existing provider's config (name, endpoint, models).
    /// Does NOT touch API keys — use addKey/updateKey/deleteKey for that.
    public func updateProvider(_ provider: AIProvider) async throws {
        try persistProvider(provider)
        try refreshCache()
        print("[AIProviderStore] Updated provider '\(provider.displayName)'")
    }

    // MARK: - Delete Provider

    /// Deletes a provider and ALL its API keys from Keychain.
    /// ALWAYS succeeds — even if this is the last provider.
    public func deleteProvider(id: UUID) async throws {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<AIProviderEntity>(
            predicate: #Predicate { $0.id == id }
        )
        guard let entity = try context.fetch(descriptor).first else {
            throw AIProviderStoreError.notFound(id)
        }

        // Remove all key secrets from Keychain before deleting the entity
        if let provider = entity.toProvider() {
            for key in provider.keys {
                deleteKeychainEntry(key: key.id.uuidString)
            }
        }

        let wasDefault = entity.isDefault
        context.delete(entity)
        try context.save()

        // Reassign default to first remaining provider
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

    /// Adds a new named API key to an existing provider.
    /// Returns the created APIKey (without the secret — secret is in Keychain).
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

    /// Updates a key's name and/or secret value.
    /// Pass nil for newValue to leave the secret unchanged.
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

        if let value = newValue, !value.isEmpty {
            saveApiKey(value, for: key.id)
        }

        try persistProvider(provider)
        try refreshCache()

        print("[AIProviderStore] Updated key '\(key.name)' on provider '\(provider.displayName)'")
    }

    /// Removes a key from a provider and deletes its Keychain entry.
    /// Threads using this key become orphaned — no blocking here.
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

    /// Adds a model name to a provider's saved model list (if not already present).
    public func addModel(_ modelName: String, toProviderId providerId: UUID) async throws {
        guard var provider = try getProviders().first(where: { $0.id == providerId }) else {
            throw AIProviderStoreError.notFound(providerId)
        }

        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !provider.models.contains(trimmed) else { return }

        provider.models.append(trimmed)
        try persistProvider(provider)
        try refreshCache()

        print("[AIProviderStore] Added model '\(trimmed)' to provider '\(provider.displayName)'")
    }

    /// Removes a model name from a provider's saved model list.
    /// Threads using this model become orphaned — no blocking here.
    public func deleteModel(_ modelName: String, fromProviderId providerId: UUID) async throws {
        guard var provider = try getProviders().first(where: { $0.id == providerId }) else {
            throw AIProviderStoreError.notFound(providerId)
        }

        provider.models.removeAll { $0 == modelName }
        try persistProvider(provider)
        try refreshCache()

        print("[AIProviderStore] Deleted model '\(modelName)' from provider '\(provider.displayName)'")
    }

    // MARK: - Default

    /// Marks a provider as default, unmarks all others.
    public func setDefault(id: UUID) async throws {
        let context = ModelContext(modelContainer)
        let allEntities = try context.fetch(FetchDescriptor<AIProviderEntity>())

        for entity in allEntities {
            entity.isDefault = (entity.id == id)
        }
        try context.save()

        try refreshCache()
        print("[AIProviderStore] Default provider set to id: \(id)")
    }

    // MARK: - API Key (Keychain)

    /// Loads the API key secret for a given APIKey.id from Keychain.
    public func loadApiKey(for keyId: UUID) -> String? {
        return keychainLoad(key: keyId.uuidString)
    }

    /// Returns true if at least one provider exists.
    public func hasProviders() async -> Bool {
        return (try? getProviders().isEmpty == false) ?? false
    }

    // MARK: - Private Helpers

    /// Persists a mutated AIProvider back to SwiftData (updates JSON in entity).
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

    // MARK: - Keychain Helpers (private)

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
        case .notFound(let id):
            return "Provider not found: \(id)"
        case .keyNotFound(let id):
            return "API key not found: \(id)"
        }
    }
}
