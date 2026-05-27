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
// THREAD SAFETY:
// All async methods run in a detached Task with ModelContainer actor isolation.
// Same pattern as ThreadStore and ProjectStore.

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
/// - setDefault(id:)
/// - loadDefaultProvider() → AIProvider?
/// - loadApiKey(for providerID:) → String?
public actor AIProviderStore {

    // MARK: - Dependencies

    private let modelContainer: ModelContainer

    // MARK: - Keychain constants

    private let keychainService: String = {
        Bundle.main.bundleIdentifier ?? "ru.chappie"
    }()

    // MARK: - Init

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Load

    /// Returns all stored providers, sorted by creation date (oldest first).
    public func loadProviders() async throws -> [AIProvider] {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<AIProviderEntity>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let entities = try context.fetch(descriptor)
        return entities.compactMap { $0.toProvider() }
    }

    /// Returns the default provider, or the first one if no default is set.
    public func loadDefaultProvider() async throws -> AIProvider? {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<AIProviderEntity>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let entities = try context.fetch(descriptor)

        // Prefer the explicitly marked default
        if let defaultEntity = entities.first(where: { $0.isDefault }) {
            return defaultEntity.toProvider()
        }
        // Fall back to the first one
        return entities.first?.toProvider()
    }

    /// Returns a single provider by ID.
    public func loadProvider(id: UUID) async throws -> AIProvider? {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<AIProviderEntity>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first?.toProvider()
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

        print("[AIProviderStore] Added provider '\(provider.displayLabel)' (id: \(provider.id))")
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

        print("[AIProviderStore] Updated provider '\(provider.displayLabel)'")
    }

    // MARK: - Delete

    /// Deletes a provider and its API key from Keychain.
    /// Throws if trying to delete the last remaining provider.
    public func deleteProvider(id: UUID) async throws {
        let context = ModelContext(modelContainer)
        let allDescriptor = FetchDescriptor<AIProviderEntity>()
        let allEntities = try context.fetch(allDescriptor)

        guard allEntities.count > 1 else {
            throw AIProviderStoreError.cannotDeleteLast
        }

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

        print("[AIProviderStore] Deleted provider id: \(id)")
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

        print("[AIProviderStore] Default provider set to id: \(id)")
    }

    // MARK: - API Key (Keychain)

    /// Loads the API key for a provider from Keychain.
    public func loadApiKey(for providerID: UUID) -> String? {
        return keychainLoad(key: providerID.uuidString)
    }

    /// Returns true if at least one provider exists.
    public func hasProviders() async -> Bool {
        let context = ModelContext(modelContainer)
        let count = (try? context.fetch(FetchDescriptor<AIProviderEntity>()).count) ?? 0
        return count > 0
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
    case cannotDeleteLast

    public var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "Provider not found: \(id)"
        case .cannotDeleteLast:
            return "Cannot delete the last remaining provider. At least one provider must exist."
        }
    }
}
