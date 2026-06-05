// DataStoreMigration.swift
// ChappieCore
//
// One-time migration from legacy @Model classes to DataStore (StoredRecord).
// Reads old SwiftData entities, encodes them into DataStore format, writes via DataStore.
//
// SAFETY CONTRACT:
// - Migration is READ-ONLY on legacy entities — nothing is deleted here.
// - Old @Model classes are removed in DB-05, after all Stores are switched to DataStore.
// - Migration is idempotent: if DataStore already has data for a relation, it is skipped.
//   This prevents double-migration if the app is launched multiple times before DB-05.
//
// MEMORY LAYOUT IN DATASTORE:
// MemoryEntity rows (one per scope) are collapsed into a single [String: [MemoryEntry]] dict.
// Key = scope string ("global", project UUID, thread UUID), value = entries array.
// This matches MemoryStore's access pattern: always read/write the full scope at once.

import Foundation
import SwiftData

// MARK: - Payload types

// Sendable Codable structs — safe to pass across actor boundaries.
// Mirror legacy @Model fields exactly so data survives the transition.

/// Portable representation of a thread for DataStore storage.
/// Mirrors ThreadEntity fields — all heavy data stays as opaque Data blobs.
public struct ThreadPayload: Codable, Sendable {
    public let id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messagesJSON: Data
    public var settingsJSON: Data
    public var projectBindingsJSON: Data

    public init(
        id: UUID,
        title: String,
        createdAt: Date,
        updatedAt: Date,
        messagesJSON: Data,
        settingsJSON: Data,
        projectBindingsJSON: Data
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messagesJSON = messagesJSON
        self.settingsJSON = settingsJSON
        self.projectBindingsJSON = projectBindingsJSON
    }
}

/// Portable representation of a project for DataStore storage.
/// Mirrors ProjectEntity fields.
public struct ProjectPayload: Codable, Sendable {
    public let id: UUID
    public var displayName: String
    public var bookmarkData: Data
    public var createdAt: Date
    public var settingsJSON: Data

    public init(
        id: UUID,
        displayName: String,
        bookmarkData: Data,
        createdAt: Date,
        settingsJSON: Data
    ) {
        self.id = id
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.createdAt = createdAt
        self.settingsJSON = settingsJSON
    }
}

/// AppSettings payload for DataStore storage.
/// Mirrors AppSettings fields exactly.
public struct AppSettingsPayload: Codable, Sendable {
    public var workspaceBookmark: Data?
    public var lastActiveThreadIdString: String?
    public var balancesJSON: Data

    public init(
        workspaceBookmark: Data? = nil,
        lastActiveThreadIdString: String? = nil,
        balancesJSON: Data = Data()
    ) {
        self.workspaceBookmark = workspaceBookmark
        self.lastActiveThreadIdString = lastActiveThreadIdString
        self.balancesJSON = balancesJSON
    }

    // CodingKeys guard against future renames — required by DataStore Codable contract.
    private enum CodingKeys: String, CodingKey {
        case workspaceBookmark = "workspace_bookmark"
        case lastActiveThreadIdString = "last_active_thread_id"
        case balancesJSON = "balances_json"
    }
}

/// Provider payload — wraps AIProvider list plus the default provider ID.
public struct ProvidersPayload: Codable, Sendable {
    /// All providers in creation order.
    public var providers: [AIProvider]
    /// UUID of the default provider. nil = use first in list.
    public var defaultProviderId: UUID?

    public init(providers: [AIProvider] = [], defaultProviderId: UUID? = nil) {
        self.providers = providers
        self.defaultProviderId = defaultProviderId
    }
}

/// Memory storage — all scopes in one dict: scope → entries.
/// Stored as a single DataStore record under Relation.memory.
public struct MemoryStorage: Codable, Sendable {
    /// scope string → array of MemoryEntry
    public var scopes: [String: [MemoryEntry]]

    public init(scopes: [String: [MemoryEntry]] = [:]) {
        self.scopes = scopes
    }
}

// MARK: - DataStoreMigration

/// Performs one-time migration from legacy @Model entities to DataStore.
/// Called once at startup, before any Store initializes.
public actor DataStoreMigration {

    private let modelContainer: ModelContainer
    private let dataStore: DataStore

    public init(modelContainer: ModelContainer, dataStore: DataStore) {
        self.modelContainer = modelContainer
        self.dataStore = dataStore
    }

    // MARK: - Entry point

    /// Runs migration for all relations that don't yet exist in DataStore.
    /// Safe to call on every launch — skips relations already migrated.
    public func migrateIfNeeded() async {
        print("[DataStoreMigration] Starting migration check...")

        await migrateThreads()
        await migrateProjects()
        await migrateMemory()
        await migrateProviders()
        await migrateAppSettings()

        print("[DataStoreMigration] Migration check complete.")
    }

    // MARK: - Threads

    private func migrateThreads() async {
        // Skip if DataStore already has threads — idempotency guard.
        guard (try? await dataStore.exists(.threads)) == false else {
            print("[DataStoreMigration] Threads: already migrated, skipping.")
            return
        }

        let context = ModelContext(modelContainer)
        guard let entities = try? context.fetch(FetchDescriptor<ThreadEntity>()) else {
            print("[DataStoreMigration] Threads: no legacy data found.")
            return
        }

        guard !entities.isEmpty else {
            print("[DataStoreMigration] Threads: legacy table empty, nothing to migrate.")
            return
        }

        // Build Sendable payloads from @Model entities before crossing the actor boundary.
        let payloads: [ThreadPayload] = entities.map { e in
            ThreadPayload(
                id: e.id,
                title: e.title,
                createdAt: e.createdAt,
                updatedAt: e.updatedAt,
                messagesJSON: e.messagesJSON,
                settingsJSON: e.settingsJSON,
                projectBindingsJSON: e.projectBindingsJSON
            )
        }

        do {
            try await dataStore.save(payloads, for: .threads)
            print("[DataStoreMigration] ✅ Threads: migrated \(payloads.count) records.")
        } catch {
            print("[DataStoreMigration] ❌ Threads migration failed: \(error)")
        }
    }

    // MARK: - Projects

    private func migrateProjects() async {
        guard (try? await dataStore.exists(.projects)) == false else {
            print("[DataStoreMigration] Projects: already migrated, skipping.")
            return
        }

        let context = ModelContext(modelContainer)
        guard let entities = try? context.fetch(FetchDescriptor<ProjectEntity>()) else {
            print("[DataStoreMigration] Projects: no legacy data found.")
            return
        }

        guard !entities.isEmpty else {
            print("[DataStoreMigration] Projects: legacy table empty, nothing to migrate.")
            return
        }

        // Build Sendable payloads before crossing the actor boundary.
        let payloads: [ProjectPayload] = entities.map { e in
            ProjectPayload(
                id: e.id,
                displayName: e.displayName,
                bookmarkData: e.bookmarkData,
                createdAt: e.createdAt,
                settingsJSON: e.settingsJSON
            )
        }

        do {
            try await dataStore.save(payloads, for: .projects)
            print("[DataStoreMigration] ✅ Projects: migrated \(payloads.count) records.")
        } catch {
            print("[DataStoreMigration] ❌ Projects migration failed: \(error)")
        }
    }

    // MARK: - Memory

    private func migrateMemory() async {
        guard (try? await dataStore.exists(.memory)) == false else {
            print("[DataStoreMigration] Memory: already migrated, skipping.")
            return
        }

        let context = ModelContext(modelContainer)
        guard let entities = try? context.fetch(FetchDescriptor<MemoryEntity>()) else {
            print("[DataStoreMigration] Memory: no legacy data found.")
            return
        }

        guard !entities.isEmpty else {
            print("[DataStoreMigration] Memory: legacy table empty, nothing to migrate.")
            return
        }

        // Collapse multiple MemoryEntity rows (one per scope) into a single dict.
        // entries property decodes from entriesJSON — value types, safe to copy.
        var scopeDict: [String: [MemoryEntry]] = [:]
        for entity in entities {
            scopeDict[entity.scope] = entity.entries
        }

        let storage = MemoryStorage(scopes: scopeDict)

        do {
            try await dataStore.save(storage, for: .memory)
            print("[DataStoreMigration] ✅ Memory: migrated \(scopeDict.count) scopes.")
        } catch {
            print("[DataStoreMigration] ❌ Memory migration failed: \(error)")
        }
    }

    // MARK: - Providers

    private func migrateProviders() async {
        guard (try? await dataStore.exists(.providers)) == false else {
            print("[DataStoreMigration] Providers: already migrated, skipping.")
            return
        }

        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<AIProviderEntity>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        guard let entities = try? context.fetch(descriptor) else {
            print("[DataStoreMigration] Providers: no legacy data found.")
            return
        }

        guard !entities.isEmpty else {
            print("[DataStoreMigration] Providers: legacy table empty, nothing to migrate.")
            return
        }

        // toProvider() returns Sendable AIProvider structs — safe to cross actor boundary.
        let providers = entities.compactMap { $0.toProvider() }
        let defaultId = entities.first(where: { $0.isDefault })?.id
        let payload = ProvidersPayload(providers: providers, defaultProviderId: defaultId)

        do {
            try await dataStore.save(payload, for: .providers)
            print("[DataStoreMigration] ✅ Providers: migrated \(providers.count) records.")
        } catch {
            print("[DataStoreMigration] ❌ Providers migration failed: \(error)")
        }
    }

    // MARK: - AppSettings

    private func migrateAppSettings() async {
        guard (try? await dataStore.exists(.appSettings)) == false else {
            print("[DataStoreMigration] AppSettings: already migrated, skipping.")
            return
        }

        let context = ModelContext(modelContainer)
        guard let entity = try? context.fetch(FetchDescriptor<AppSettings>()).first else {
            // No legacy record — create a blank default so DataStore is initialized.
            let blank = AppSettingsPayload()
            try? await dataStore.save(blank, for: .appSettings)
            print("[DataStoreMigration] AppSettings: no legacy record, created blank default.")
            return
        }

        // Copy primitive/value fields out of @Model before crossing the actor boundary.
        let payload = AppSettingsPayload(
            workspaceBookmark: entity.workspaceBookmark,
            lastActiveThreadIdString: entity.lastActiveThreadIdString,
            balancesJSON: entity.balancesJSON
        )

        do {
            try await dataStore.save(payload, for: .appSettings)
            print("[DataStoreMigration] ✅ AppSettings: migrated successfully.")
        } catch {
            print("[DataStoreMigration] ❌ AppSettings migration failed: \(error)")
        }
    }
}
