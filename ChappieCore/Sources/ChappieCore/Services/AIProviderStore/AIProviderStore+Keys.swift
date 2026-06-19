// AIProviderStore+Keys.swift
// ChappieCore
//
// API key CRUD + Keychain read/write/delete.

import Foundation
import Security

extension AIProviderStore {

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
    }

    // MARK: - Keychain

    public func loadApiKey(for keyId: UUID) -> String? {
        return keychainLoad(key: keyId.uuidString)
    }

    func saveApiKey(_ value: String, for keyId: UUID) {
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

    func keychainLoad(key: String) -> String? {
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

    func deleteKeychainEntry(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: keychainService
        ]
        SecItemDelete(query as CFDictionary)
    }
}
