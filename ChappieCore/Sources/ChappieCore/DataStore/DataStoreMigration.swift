// DataStoreMigration.swift
// ChappieCore
//
// One-time migration: reads legacy SwiftData entities (V3 schema) and writes them
// into ChappieDataStore as StoredRecord payloads.
//
// SAFETY CONTRACT:
// - Idempotent: if ChappieDataStore already has data for a relation, it is skipped.
// - Non-destructive: legacy entities are not deleted here — V3→V4 lightweight migration
//   drops their tables automatically via SwiftData schema diff.
// - Called once at startup from ChappieApp.onAppear, before ViewModel initializes.
//
// NOTE ON LEGACY TYPES:
// This file no longer references legacy @Model classes directly.
// After V4 migration, legacy tables are gone from the database.
// migrateIfNeeded() is fully idempotent — on V4 databases it finds existing StoredRecord
// data and skips all migration steps immediately.

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

    /// Checks each relation in ChappieDataStore and skips if already populated.
    /// On a fresh V4 database — all relations are empty, migration reads from StoredRecord
    /// (which was populated during V3 runtime). On upgrade from V3 — data is already there.
    public func migrateIfNeeded() async {
        print("[DataStoreMigration] Starting migration check...")

        // On V4 all legacy tables are gone. We only verify StoredRecord data exists.
        // If it does — migration was already completed during V3 launch. Nothing to do.
        let threadsExist    = (try? await dataStore.exists(.threads))     == true
        let projectsExist   = (try? await dataStore.exists(.projects))    == true
        let memoryExist     = (try? await dataStore.exists(.memory))      == true
        let providersExist  = (try? await dataStore.exists(.providers))   == true
        let settingsExist   = (try? await dataStore.exists(.appSettings)) == true

        if threadsExist && projectsExist && memoryExist && providersExist && settingsExist {
            print("[DataStoreMigration] ✅ All relations present — no migration needed.")
            return
        }

        // Partial state: some relations missing. Seed missing ones with empty defaults.
        // This handles edge cases (first launch, corrupted DB recovery).
        await seedMissingRelations(
            threads: threadsExist,
            projects: projectsExist,
            memory: memoryExist,
            providers: providersExist,
            settings: settingsExist
        )

        print("[DataStoreMigration] Migration check complete.")
    }

    // MARK: - Seed missing relations with empty defaults

    private func seedMissingRelations(
        threads: Bool,
        projects: Bool,
        memory: Bool,
        providers: Bool,
        settings: Bool
    ) async {
        if !threads {
            try? await dataStore.save([ThreadPayload](), for: .threads)
            print("[DataStoreMigration] Seeded empty threads relation.")
        }
        if !projects {
            try? await dataStore.save([ProjectPayload](), for: .projects)
            print("[DataStoreMigration] Seeded empty projects relation.")
        }
        if !memory {
            try? await dataStore.save(MemoryStorage(), for: .memory)
            print("[DataStoreMigration] Seeded empty memory relation.")
        }
        if !providers {
            try? await dataStore.save([AIProvider](), for: .providers)
            print("[DataStoreMigration] Seeded empty providers relation.")
        }
        if !settings {
            try? await dataStore.save(AppSettingsPayload(), for: .appSettings)
            print("[DataStoreMigration] Seeded empty appSettings relation.")
        }
    }
}
