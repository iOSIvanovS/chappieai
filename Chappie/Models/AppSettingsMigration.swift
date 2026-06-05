// AppSettingsMigration.swift
// Chappie
//
// SwiftData schema versioning.
//
// HISTORY:
// V1 → V2: "New.AppSettings" entity renamed to "AppSettings" (namespace removal).
// V2 → V3: StoredRecord added alongside legacy @Model classes.
// V3 → V4: Legacy @Model classes removed. StoredRecord is the only permanent model.
//           DataStoreMigration.migrateIfNeeded() ran on V3 launch — all data is in StoredRecord.
//
// DO NOT REMOVE: SwiftData stores schema version history in the database.
// Removing any version from the chain breaks migration on devices that ran older builds.
//
// IMPORTANT: V1/V2/V3 schemas reference legacy @Model types that no longer exist in code.
// They are kept as inline-defined stubs inside their VersionedSchema enums to satisfy
// SwiftData's migration chain requirement without polluting the live codebase.

import Foundation
import SwiftData
import ChappieCore

// MARK: - Schema V1 (legacy stub)

enum AppSettingsSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    // Legacy models — referenced only for migration chain continuity.
    static var models: [any PersistentModel.Type] {
        [LegacyAppSettings.self, LegacyThreadEntity.self,
         LegacyProjectEntity.self, LegacyMemoryEntity.self, LegacyAIProviderEntity.self]
    }
}

// MARK: - Schema V2 (legacy stub)

enum AppSettingsSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [LegacyAppSettings.self, LegacyThreadEntity.self,
         LegacyProjectEntity.self, LegacyMemoryEntity.self, LegacyAIProviderEntity.self]
    }
}

// MARK: - Schema V3 (legacy stub)

/// V3: StoredRecord joined the schema alongside legacy @Model classes.
/// All data was migrated from legacy → StoredRecord during V3 runtime via DataStoreMigration.
enum AppSettingsSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        [LegacyAppSettings.self, LegacyThreadEntity.self,
         LegacyProjectEntity.self, LegacyMemoryEntity.self, LegacyAIProviderEntity.self,
         StoredRecord.self]
    }
}

// MARK: - Schema V4 (current)

/// V4: Only StoredRecord remains. All legacy @Model classes are gone.
/// This is the permanent schema — StoredRecord.relation/payload never changes.
enum AppSettingsSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        [StoredRecord.self]
    }
}

// MARK: - Migration Plan

enum AppSettingsMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [AppSettingsSchemaV1.self, AppSettingsSchemaV2.self,
         AppSettingsSchemaV3.self, AppSettingsSchemaV4.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3, migrateV3toV4]
    }

    /// V1 → V2: Ensures at least one AppSettings record exists after the entity rename.
    static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: AppSettingsSchemaV1.self,
        toVersion: AppSettingsSchemaV2.self,
        willMigrate: nil,
        didMigrate: { context in
            let existing = try context.fetch(FetchDescriptor<LegacyAppSettings>())
            if existing.isEmpty {
                context.insert(LegacyAppSettings())
                try context.save()
            }
        }
    )

    /// V2 → V3: Lightweight — just adds the StoredRecord table.
    static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: AppSettingsSchemaV2.self,
        toVersion: AppSettingsSchemaV3.self
    )

    /// V3 → V4: Lightweight — just drops legacy tables.
    /// Data was already migrated to StoredRecord by DataStoreMigration at V3 runtime.
    static let migrateV3toV4 = MigrationStage.lightweight(
        fromVersion: AppSettingsSchemaV3.self,
        toVersion: AppSettingsSchemaV4.self
    )
}

// MARK: - Legacy Model Stubs
// Minimal @Model stubs kept solely to satisfy SwiftData's migration chain.
// These types are NOT used anywhere in production code.
// DO NOT add business logic here. DO NOT reference these outside migration schemas.

@Model final class LegacyAppSettings {
    var workspaceBookmark: Data?
    var lastActiveThreadIdString: String?
    var balancesJSON: Data
    init() { self.balancesJSON = Data() }
}

@Model final class LegacyThreadEntity {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messagesJSON: Data
    var settingsJSON: Data
    var projectBindingsJSON: Data
    init() {
        self.id = UUID(); self.title = ""; self.createdAt = Date(); self.updatedAt = Date()
        self.messagesJSON = Data(); self.settingsJSON = Data(); self.projectBindingsJSON = Data()
    }
}

@Model final class LegacyProjectEntity {
    var id: UUID
    var displayName: String
    var bookmarkData: Data
    var createdAt: Date
    var settingsJSON: Data
    init() {
        self.id = UUID(); self.displayName = ""; self.bookmarkData = Data()
        self.createdAt = Date(); self.settingsJSON = Data()
    }
}

@Model final class LegacyMemoryEntity {
    var id: UUID
    var scope: String
    var entriesJSON: Data
    var updatedAt: Date
    init() {
        self.id = UUID(); self.scope = ""; self.entriesJSON = Data(); self.updatedAt = Date()
    }
}

@Model final class LegacyAIProviderEntity {
    var id: UUID
    var json: String
    var isDefault: Bool
    var createdAt: Date
    init() {
        self.id = UUID(); self.json = "{}"; self.isDefault = false; self.createdAt = Date()
    }
}
