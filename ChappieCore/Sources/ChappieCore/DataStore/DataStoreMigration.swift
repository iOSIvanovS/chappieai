// DataStoreMigration.swift
// ChappieCore
//
// One-time migration from legacy @Model classes to ChappieDataStore (StoredRecord).
// Reads old SwiftData entities, encodes them into ChappieDataStore format, writes via ChappieDataStore.
//
// SAFETY CONTRACT:
// - Migration is READ-ONLY on legacy entities — nothing is deleted here.
// - Old @Model classes are removed in DB-05, after all Stores are switched to ChappieDataStore.
// - Migration is idempotent: if ChappieDataStore already has data for a relation, it is skipped.
//
// STORAGE FORMAT (matches what the new Stores expect):
// - Relation.threads              → [ThreadPayload]       (ThreadStore.swift)
// - Relation.threadMessages(uuid) → raw JSON Data         (saveRawData — already-encoded JSON)
// - Relation.projects             → [ProjectPayload]      (ProjectStore.swift)
// - Relation.projectBookmark(uuid)→ Data                  (save<Data>)
// - Relation.memory               → MemoryStorage         (MemoryModels.swift)
// - Relation.providers            → [AIProvider]          (AIProviderModels.swift)
// - Relation.appSettings          → AppSettingsPayload    (AppSettingsStore.swift)

import Foundation
import SwiftData

// MARK: - DataStoreMigration

public actor DataStoreMigration {

    private let modelContainer: ModelContainer
    private let dataStore: ChappieDataStore

    public init(modelContainer: ModelContainer, dataStore: ChappieDataStore) {
        self.modelContainer = modelContainer
        self.dataStore = dataStore
    }

    // MARK: - Entry point

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
        guard (try? await dataStore.exists(.threads)) == false else {
            print("[DataStoreMigration] Threads: already migrated, skipping.")
            return
        }

        let context = ModelContext(modelContainer)
        guard let entities = try? context.fetch(FetchDescriptor<ThreadEntity>()),
              !entities.isEmpty else {
            print("[DataStoreMigration] Threads: no legacy data found.")
            return
        }

        // Build ThreadPayload array matching ThreadStore's storage format.
        let payloads: [ThreadPayload] = entities.map { e in
            ThreadPayload(
                id: e.id,
                title: e.title,
                settings: (try? JSONDecoder().decode(ThreadSettings.self, from: e.settingsJSON)) ?? ThreadSettings(),
                projectIds: (try? JSONDecoder().decode([UUID].self, from: e.projectBindingsJSON)) ?? []
            )
        }

        do {
            try await dataStore.save(payloads, for: .threads)

            // Migrate per-thread messages as raw JSON Data (saveRawData — no re-encoding).
            for entity in entities where !entity.messagesJSON.isEmpty {
                let relation = ChappieDataStore.Relation.threadMessages(entity.id)
                guard (try? await dataStore.exists(relation)) == false else { continue }
                try await dataStore.saveRawData(entity.messagesJSON, for: relation)
            }

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
        guard let entities = try? context.fetch(FetchDescriptor<ProjectEntity>()),
              !entities.isEmpty else {
            print("[DataStoreMigration] Projects: no legacy data found.")
            return
        }

        let payloads: [ProjectPayload] = entities.map { e in
            ProjectPayload(id: e.id, displayName: e.displayName, settings: e.settings)
        }

        do {
            try await dataStore.save(payloads, for: .projects)

            // Migrate per-project bookmarks.
            for entity in entities {
                let relation = ChappieDataStore.Relation.projectBookmark(entity.id)
                guard (try? await dataStore.exists(relation)) == false else { continue }
                try await dataStore.save(entity.bookmarkData, for: relation)
            }

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
        guard let entities = try? context.fetch(FetchDescriptor<MemoryEntity>()),
              !entities.isEmpty else {
            print("[DataStoreMigration] Memory: no legacy data found.")
            return
        }

        var scopeDict: [String: [MemoryEntry]] = [:]
        for entity in entities {
            scopeDict[entity.scope] = entity.entries
        }

        do {
            try await dataStore.save(MemoryStorage(scopes: scopeDict), for: .memory)
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
        guard let entities = try? context.fetch(descriptor),
              !entities.isEmpty else {
            print("[DataStoreMigration] Providers: no legacy data found.")
            return
        }

        // Decode providers and embed isDefault from the entity row.
        var providers: [AIProvider] = []
        for entity in entities {
            if var provider = entity.toProvider() {
                provider.isDefault = entity.isDefault
                providers.append(provider)
            }
        }

        // Ensure exactly one default.
        if !providers.isEmpty, !providers.contains(where: { $0.isDefault }) {
            providers[0].isDefault = true
        }

        do {
            try await dataStore.save(providers, for: .providers)
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
            try? await dataStore.save(AppSettingsPayload(), for: .appSettings)
            print("[DataStoreMigration] AppSettings: no legacy record, created blank default.")
            return
        }

        // Convert legacy [String: Double] balances dict to the new format.
        let balances = entity.balances  // already [String: Double] from AppSettings.balances getter

        let payload = AppSettingsPayload(
            workspaceBookmark: entity.workspaceBookmark,
            lastActiveThreadId: entity.lastActiveThreadId,
            balances: balances
        )

        do {
            try await dataStore.save(payload, for: .appSettings)
            print("[DataStoreMigration] ✅ AppSettings: migrated successfully.")
        } catch {
            print("[DataStoreMigration] ❌ AppSettings migration failed: \(error)")
        }
    }
}
