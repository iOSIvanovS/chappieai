// AIProviderStore.swift
// ChappieCore
//
// CRUD service for AI providers — SwiftData backend, Keychain for API keys.
//
// ARCHITECTURE:
// - AIProviderEntity in SwiftData stores provider config as JSON (no graph pattern)
// - API keys live exclusively in Keychain, keyed by provider.id.uuidString
// - This class is the single source of truth for provider management
//
// DELETION POLICY (providers refactor):
// Deletion is ALWAYS allowed — even the last provider, even if threads depend on it.
// Orphaned threads (provider or model missing) show a warning banner in the chat view.
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
// This eliminates read contention during thread switching (no concurrent ModelContext fetches).
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
/// - addProvider(_ provider:, apiKey:) → UUID
/// - updateProvider(_ provider:, apiKey:)
/// - deleteProvider(id:)
/// - addModel(_ modelName:, toProviderId:)
/// - deleteModel(_ modelName:, fromProviderId:)
/// - setDefault(id:)
/// - loadDefaultProvider() → AIProvider?
/// - loadApiKey(for providerID:) → String?
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
        // Track which UUID is marked as default so loadDefaultProvider() needs no DB hit
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
    public func loadProviders() async throws -> [AIProvider] {
        return try getProviders()
    }

    /// Returns the default provider, or the first one if no default is set.
    /// Served from in-memory cache — no SwiftData hit on warm calls.
    public func loadDefaultProvider() async throws -> AIProvider? {
        let providers = try getProviders()
        if let defaultId = cachedDefaultId,
           let found = providers.first(where: { $0.id == defaultId }) {
            return found
        }
        return providers.first
    }

    /// Returns a single provider by ID.
    /// Served from in-memory cache — no SwiftData hit on warm calls.
    public func loadProvider(id: UUID) async throws -> AIProvider? {
        return try getProviders().first(where: { $0.id == id })
    }

    // MARK: - Add

    /// Persists a new provider and saves its API key to Keychain.
    /// Returns the new provider's UUID.
    @discardableResult
    public func addProvider(_ provider: AIProvider, apiKey: String) async throws -> UUID {
        let context = ModelContext(modelContainer)
        let entity = AIProviderEntity(provider: provider, isDefault: false)

        // If this is the first provider — make it default automatically
        let existingCount = (try? context.fetch(FetchDescriptor<AIProviderEntity>()).count) ?? 0
        if existingCount == 0 {
            entity.isDefault = true
        }

        context.insert(entity)
        try context.save()

        // Store API key in Keychain
        saveApiKey(apiKey, for: provider.id)

        // Invalidate cache — next read will reflect the new provider
        try refreshCache()

        print("[AIProviderStore] Added provider '\(provider.displayName)' (id: \(provider.id))")
        return provider.id
    }

    // MARK: - Update

    /// Updates an existing provider's config and optionally its API key.
    /// Pass nil for apiKey to leave the existing key unchanged.
    public func updateProvider(_ provider: AIProvider, apiKey: String?) async throws {
        let context = ModelContext(modelContainer)
        let id = provider.id
        let descriptor = FetchDescriptor<AIProviderEntity>(
            predicate: #Predicate { $0.id == id }
        )
        guard let entity = try context.fetch(descriptor).first else {
            throw AIProviderStoreError.notFound(id)
        }

        entity.update(from: provider)
        try context.save()

        if let key = apiKey, !key.isEmpty {
            saveApiKey(key, for: provider.id)
        }

        try refreshCache()

        print("[AIProviderStore] Updated provider '\(provider.displayName)'")
    }

    // MARK: - Delete

    /// Deletes a provider and its API key from Keychain.
    /// ALWAYS succeeds — even if this is the last provider.
    /// Threads that depended on this provider become orphaned (UI shows warning).
    public func deleteProvider(id: UUID) async throws {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<AIProviderEntity>(
            predicate: #Predicate { $0.id == id }
        )
        guard let entity = try context.fetch(descriptor).first else {
            throw AIProviderStoreError.notFound(id)
        }

        let wasDefault = entity.isDefault
        context.delete(entity)
        try context.save()

        // If deleted provider was default — assign default to the first remaining
        if wasDefault {
            let remaining = try context.fetch(FetchDescriptor<AIProviderEntity>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            ))
            if let first = remaining.first {
                first.isDefault = true
                try context.save()
            }
        }

        // Remove API key from Keychain
        deleteApiKey(for: id)

        try refreshCache()

        print("[AIProviderStore] Deleted provider id: \(id)")
    }

    // MARK: - Model Management

    /// Adds a model name to a provider's saved model list (if not already present).
    public func addModel(_ modelName: String, toProviderId providerId: UUID) async throws {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<AIProviderEntity>(
            predicate: #Predicate { $0.id == providerId }
        )
        guard let entity = try context.fetch(descriptor).first,
              var provider = entity.toProvider() else {
            throw AIProviderStoreError.notFound(providerId)
        }

        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !provider.models.contains(trimmed) else { return }

        provider.models.append(trimmed)
        entity.update(from: provider)
        try context.save()

        try refreshCache()

        print("[AIProviderStore] Added model '\(trimmed)' to provider '\(provider.displayName)'")
    }

    /// Removes a model name from a provider's saved model list.
    /// Threads using this model become orphaned — no blocking here.
    public func deleteModel(_ modelName: String, fromProviderId providerId: UUID) async throws {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<AIProviderEntity>(
            predicate: #Predicate { $0.id == providerId }
        )
        guard let entity = try context.fetch(descriptor).first,
              var provider = entity.toProvider() else {
            throw AIProviderStoreError.notFound(providerId)
        }

        provider.models.removeAll { $0 == modelName }
        entity.update(from: provider)
        try context.save()

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

    /// Loads the API key for a provider from Keychain.
    public func loadApiKey(for providerID: UUID) -> String? {
        return keychainLoad(key: providerID.uuidString)
    }

    /// Returns true if at least one provider exists.
    public func hasProviders() async -> Bool {
        return (try? getProviders().isEmpty == false) ?? false
    }

    // MARK: - Keychain Helpers (private)

    private func saveApiKey(_ value: String, for providerID: UUID) {
        guard let data = value.data(using: .utf8) else { return }
        let key = providerID.uuidString
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

    private func deleteApiKey(for providerID: UUID) {
        let key = providerID.uuidString
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

    public var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "Provider not found: \(id)"
        }
    }
}
