// CurlSecretKeychain.swift
// ChappieCore
//
// Keychain storage for Curl-Chappie secret VALUES. Metadata lives in ProjectSettings.
//
// Account layout: "<secretId>.<field>" under a dedicated service, so one secret with two
// parts (login + password) is two Keychain items and deleting a secret removes both.
//
// WHY A VALUE TYPE WITH AN INJECTABLE SERVICE:
// Tests use a unique service name and clean up after themselves, so they never touch the
// real items.
//
// Values are excluded from backups on purpose (Keychain only): after migrating to a new
// Mac the user re-enters them. `missingFields` tells the UI which ones to ask for.

import Foundation
import Security

public struct CurlSecretKeychain: Sendable {

    public let service: String

    public init(service: String? = nil) {
        self.service = service ?? ((Bundle.main.bundleIdentifier ?? "ru.chappie") + ".curl")
    }

    private func baseQuery(secretId: UUID, field: CurlSecretField) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(secretId.uuidString).\(field.rawValue)"
        ]
    }

    /// Replaces any existing value. An empty string deletes the item instead of storing "".
    @discardableResult
    public func save(_ value: String, secretId: UUID, field: CurlSecretField) -> Bool {
        let query = baseQuery(secretId: secretId, field: field)
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return value.isEmpty }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public func load(secretId: UUID, field: CurlSecretField) -> String? {
        var query = baseQuery(secretId: secretId, field: field)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    /// Removes every part of one secret.
    public func delete(secretId: UUID) {
        for field in CurlSecretField.allCases {
            SecItemDelete(baseQuery(secretId: secretId, field: field) as CFDictionary)
        }
    }

    /// Removes the values of all given secrets — call when a project is detached or deleted.
    public func deleteAll(_ secrets: [CurlSecret]) {
        secrets.forEach { delete(secretId: $0.id) }
    }

    /// Parts of `secret` that have no value in the Keychain (e.g. after a backup restore).
    public func missingFields(of secret: CurlSecret) -> [CurlSecretField] {
        secret.kind.fields.filter { load(secretId: secret.id, field: $0) == nil }
    }
}
