// AIProviderStore+Backup.swift
// ChappieCore
//
// Import helper for full-settings restore (machine migration, see BackupService).
// Destructive: wipes existing providers + their Keychain secrets, then writes the
// imported set. No merge — matches the full-restore semantics agreed for this feature.

import Foundation

extension AIProviderStore {

    /// Replaces all providers and re-seeds Keychain secrets from the import bundle.
    public func importAll(_ exported: [ExportedProvider]) async throws {
        let existing = try await getProviders()
        for provider in existing {
            for key in provider.keys { deleteKeychainEntry(key: key.id.uuidString) }
        }

        var importedProviders: [AIProvider] = []
        importedProviders.reserveCapacity(exported.count)

        for item in exported {
            importedProviders.append(item.provider)
            for key in item.provider.keys {
                guard let secret = item.keySecrets[key.id.uuidString] else { continue }
                saveApiKey(secret, for: key.id)
            }
        }

        try await saveProviders(importedProviders)
        try await refreshCache()
        print("[AIProviderStore] 📦 Imported \(importedProviders.count) providers")
    }
}
