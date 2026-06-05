// AppSettingsMigration.swift
// Chappie
//
// SwiftData schema versioning.
//
// HISTORY:
// V1 → V2: "New.AppSettings" entity renamed to "AppSettings" (namespace removal).
// V2 → V3: StoredRecord added alongside legacy @Model classes.
//           Legacy classes are kept in schema until DB-05 (data migration complete).
//           After DB-05 they will be removed in a V4 schema bump.
//
// DO NOT REMOVE: SwiftData stores schema version history in the database.
// Removing any version from the chain breaks migration on devices that ran older builds.

import Foundation
import SwiftData
import ChappieCore

// MARK: - Schema V1

enum AppSettingsSchemaV1: VersionedSchema {
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

// MARK: - Schema V2

enum AppSettingsSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

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

// MARK: - Schema V3

/// V3: StoredRecord joins the schema alongside legacy @Model classes.
/// Legacy classes remain until all Stores are switched to DataStore (DB-03/04).
/// They will be dropped in V4 once DB-05 is complete.
enum AppSettingsSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            ThreadEntity.self,
            ProjectEntity.self,
            MemoryEntity.self,
            AIProviderEntity.self,
            AppSettings.self,
            StoredRecord.self   // new — the only permanent @Model going forward
        ]
    }
}

// MARK: - Migration Plan

enum AppSettingsMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [AppSettingsSchemaV1.self, AppSettingsSchemaV2.self, AppSettingsSchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3]
    }

    /// V1 → V2: Ensures at least one AppSettings record exists after the entity rename.
    /// The old "New.AppSettings" table is orphaned — AppSettingsStore.fetchOrCreate()
    /// re-populates it on first access.
    static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: AppSettingsSchemaV1.self,
        toVersion: AppSettingsSchemaV2.self,
        willMigrate: nil,
        didMigrate: { context in
            let existing = try context.fetch(FetchDescriptor<AppSettings>())
            if existing.isEmpty {
                let fresh = AppSettings()
                context.insert(fresh)
                try context.save()
                print("[Migration V1→V2] Created fresh AppSettings record after entity rename.")
            }
        }
    )

    /// V2 → V3: Lightweight migration — just adds the StoredRecord table.
    /// Actual data migration (legacy @Model → StoredRecord) happens at runtime
    /// via DataStoreMigration.migrateIfNeeded(), called from ChappieApp on first launch.
    static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: AppSettingsSchemaV2.self,
        toVersion: AppSettingsSchemaV3.self
    )
}
