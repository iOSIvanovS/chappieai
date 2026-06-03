// AppSettingsMigration.swift
// Chappie
//
// SwiftData schema versioning for AppSettings.
// Handles the one-time rename: "New.AppSettings" → "AppSettings" (namespace removal).
//
// WHY THIS EXISTS:
//   SwiftData identifies @Model classes by their fully-qualified Swift type name.
//   "New.AppSettings" and "AppSettings" are different strings — without this plan
//   SwiftData would silently create a new empty table and discard all saved settings.
//
// DO NOT REMOVE: SwiftData stores schema version history in the database.
//   Removing AppSettingsMigrationPlan would break the migration chain on any device
//   that ran the app before the rename.

import Foundation
import SwiftData
import ChappieCore

// MARK: - Schema V1

enum AppSettingsSchemaV1: VersionedSchema {
    // Must be `let` — static var is nonisolated mutable state (Swift 6 concurrency error).
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            ThreadEntity.self,
            ProjectEntity.self,
            MemoryEntity.self,
            AIProviderEntity.self,
            AppSettings.self
        ]
    }
}

// MARK: - Migration Plan

enum AppSettingsMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [AppSettingsSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    /// Ensures at least one AppSettings record exists after the entity rename.
    /// The old "New.AppSettings" table is orphaned — AppSettingsStore.fetchOrCreate()
    /// re-populates it on first access.
    static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: AppSettingsSchemaV1.self,
        toVersion: AppSettingsSchemaV1.self,
        willMigrate: nil,
        didMigrate: { context in
            let existing = try context.fetch(FetchDescriptor<AppSettings>())
            if existing.isEmpty {
                let fresh = AppSettings()
                context.insert(fresh)
                try context.save()
                print("[AppSettingsMigration] Created fresh AppSettings record after entity rename")
            }
        }
    )
}
