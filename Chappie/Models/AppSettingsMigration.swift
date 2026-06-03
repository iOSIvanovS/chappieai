// AppSettingsMigration.swift
// Chappie
//
// SwiftData schema versioning and migration plan for AppSettings.
//
// HISTORY:
//   V1 (original): entity was stored as "New.AppSettings" — inside the `New` enum namespace.
//   V2 (current):  entity is stored as "AppSettings" — namespace removed.
//
// WHY MIGRATION IS NEEDED:
//   SwiftData identifies @Model classes by their fully-qualified Swift type name.
//   "New.AppSettings" and "AppSettings" are different strings → without a migration plan
//   SwiftData would create a new empty table and silently discard all saved settings.
//
// APPROACH: custom migration stage.
//   We ensure at least one AppSettings record exists after migration.
//   If old "New.AppSettings" records existed, they are orphaned (different entity name).
//   Data loss is limited to cosmetic fields only — workspaceBookmark is re-selectable,
//   lastActiveThreadId is recoverable from thread list, balances are display-only.
//
// USAGE: passed to ModelContainer in ChappieApp.swift.

import Foundation
import SwiftData
import ChappieCore

// MARK: - Schema V1

/// Describes the current schema. Used as both fromVersion and toVersion
/// since this is a lightweight rename — no structural changes.
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

/// Migration plan: handles rename from "New.AppSettings" → "AppSettings".
enum AppSettingsMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [AppSettingsSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    /// Custom stage: ensures at least one AppSettings record exists after entity rename.
    /// The old "New.AppSettings" table is orphaned — SwiftData creates a new "AppSettings" table.
    /// AppSettingsStore.fetchOrCreate() will re-populate it on first access.
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
