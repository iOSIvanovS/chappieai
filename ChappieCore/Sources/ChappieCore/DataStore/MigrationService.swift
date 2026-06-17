// MigrationService.swift
// ChappieCore
//
// One-time migration from SwiftData (ChappieDataStore) to SQLite (SQLiteStorage).
//
// SAFETY CONTRACT:
// - Flag is set ALWAYS after first attempt — no infinite retry loops.
// - New users (empty SwiftData) or corrupted SwiftData → flag set, SQLite starts clean.
// - Each relation is migrated independently — partial failure doesn't block others.
// - All errors are logged but never thrown — app must start regardless.

import Foundation

// MARK: - MigrationService

public actor MigrationService {

    // MARK: - Constants

    private static let migrationDoneKey = "swiftdata_migration_done"

    // MARK: - Dependencies

    private let source: any ChappieStorage  // SwiftData backend
    private let target: any ChappieStorage  // SQLite backend

    // MARK: - Init

    public init(source: any ChappieStorage, target: any ChappieStorage) {
        self.source = source
        self.target = target
    }

    // MARK: - Public API

    /// Runs migration if it hasn't been completed yet.
    /// Safe to call on every app launch — exits immediately if already done.
    /// Always marks migration as done after first attempt, even if SwiftData is
    /// empty or corrupted — SQLite simply starts clean for new users.
    public func migrateIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: Self.migrationDoneKey) else {
            print("[MigrationService] ✅ Already migrated — skipping")
            return
        }

        print("[MigrationService] 🚀 Starting SwiftData → SQLite migration...")

        await migrateScalarRelations()
        await migrateThreadMessages()

        // Always set the flag — new users and corrupted SwiftData both start clean on SQLite
        UserDefaults.standard.set(true, forKey: Self.migrationDoneKey)
        print("[MigrationService] ✅ Migration complete (SQLite is now primary backend)")
    }

    // MARK: - Private

    /// Migrates all scalar relations independently — one failure doesn't block others.
    private func migrateScalarRelations() async {
        let scalars: [ChappieStorageRelation] = [
            .threads,
            .projects,
            .memory,
            .providers,
            .appSettings
        ]

        for relation in scalars {
            do {
                guard let data = try await source.loadRawData(relation) else {
                    print("[MigrationService] ⚠️ No data for '\(relation.key)' — skipping (new user or empty)")
                    continue
                }
                try await target.saveRawData(data, for: relation)
                print("[MigrationService] ✓ Migrated '\(relation.key)' (\(data.count) bytes)")
            } catch {
                // Corrupted SwiftData or read failure — skip this relation, SQLite stays empty for it
                print("[MigrationService] ⚠️ Skipped '\(relation.key)': \(error)")
            }
        }
    }

    /// Reads thread list from SQLite (already migrated), then copies messages for each thread.
    private func migrateThreadMessages() async {
        do {
            guard let threadsData = try await target.loadRawData(.threads) else {
                print("[MigrationService] ⚠️ No threads in SQLite — skipping message migration")
                return
            }

            let threadIDs = extractThreadIDs(from: threadsData)
            print("[MigrationService] 📋 Migrating messages for \(threadIDs.count) threads...")

            for id in threadIDs {
                let relation = ChappieStorageRelation.threadMessages(id)
                do {
                    guard let data = try await source.loadRawData(relation) else { continue }
                    try await target.saveRawData(data, for: relation)
                    print("[MigrationService] ✓ Messages for thread \(id.uuidString.prefix(8))… (\(data.count) bytes)")
                } catch {
                    // One thread's messages failing doesn't block others
                    print("[MigrationService] ⚠️ Skipped messages for thread \(id.uuidString.prefix(8))…: \(error)")
                }
            }
        } catch {
            print("[MigrationService] ⚠️ Could not load threads for message migration: \(error)")
        }
    }

    /// Extracts UUIDs from raw threads JSON without importing ThreadModels.
    private func extractThreadIDs(from data: Data) -> [UUID] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            print("[MigrationService] ⚠️ Could not parse threads JSON")
            return []
        }
        return json.compactMap { dict in
            guard let idString = dict["id"] as? String else { return nil }
            return UUID(uuidString: idString)
        }
    }
}
