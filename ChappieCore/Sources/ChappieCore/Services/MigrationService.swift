// MigrationService.swift
// ChappieCore
//
// One-time migration from legacy files into SwiftData (REFACTOR-THREADS IT-04).
// Migrates: chat_history.json → ThreadEntity, semantic.json → MemoryEntity (scope=global).
//
// Idempotent: guarded by "migration_v1_done" UserDefaults flag.
// Old files are NOT deleted — kept as backup.
//
// Generic T: Codable — ChappieCore doesn't know about ChatMessage (UI target).
// UI layer calls: await migrationService.migrate(messageType: ChatMessage.self, ...)

import Foundation
import SwiftData

// MARK: - MigrationService

/// One-time migration service for legacy data into SwiftData.
/// Actor ensures migrate() is never called concurrently.
public actor MigrationService {

    // MARK: - Constants

    /// UserDefaults key for the migration-done flag.
    /// Stored in UserDefaults (not SwiftData) so it's readable before SwiftData initializes.
    private static let migrationFlagKey = "migration_v1_done"
    private static let defaultThreadTitle = "Основной"

    // MARK: - Dependencies

    private let threadStore: ThreadStore
    private let memoryStore: MemoryStore
    private let fileManager = FileManager.default

    public init(threadStore: ThreadStore, memoryStore: MemoryStore) {
        self.threadStore = threadStore
        self.memoryStore = memoryStore
    }

    // MARK: - Public API

    /// Runs migration if not already done. Returns true if migration was performed.
    ///
    /// - Parameters:
    ///   - messageType: Codable type for deserializing messages (e.g. ChatMessage.self)
    ///   - chatHistoryURL: URL of chat_history.json
    ///   - semanticMemoryURL: URL of legacy semantic.json
    public func migrate<T: Codable>(
        messageType: T.Type,
        chatHistoryURL: URL,
        semanticMemoryURL: URL
    ) async -> Bool {
        guard !UserDefaults.standard.bool(forKey: Self.migrationFlagKey) else {
            print("[MigrationService] ✅ Already migrated, skipping")
            return false
        }

        print("[MigrationService] 🚀 Starting legacy data migration...")

        await migrateChatHistory(messageType: messageType, from: chatHistoryURL)
        await migrateSemanticMemory(from: semanticMemoryURL)

        // Flag is set AFTER both steps complete.
        // If the app crashes mid-migration, it will retry on next launch — safe to repeat.
        UserDefaults.standard.set(true, forKey: Self.migrationFlagKey)

        print("[MigrationService] ✅ Migration complete")
        return true
    }

    /// Resets the migration flag — next migrate() call will re-run. For debug/tests only.
    public func resetMigrationFlag() {
        UserDefaults.standard.removeObject(forKey: Self.migrationFlagKey)
        print("[MigrationService] ⚠️ Migration flag reset (debug only)")
    }

    public var isMigrationDone: Bool {
        UserDefaults.standard.bool(forKey: Self.migrationFlagKey)
    }

    // MARK: - Private

    /// Reads chat_history.json and saves messages into a new "Основной" thread.
    /// Creates an empty thread if the file is missing or corrupt.
    private func migrateChatHistory<T: Codable>(messageType: T.Type, from url: URL) async {
        print("[MigrationService] 📨 Migrating chat history from \(url.lastPathComponent)...")

        let messages: [T]
        if fileManager.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([T].self, from: data) {
            messages = decoded
            print("[MigrationService] 📨 Loaded \(messages.count) messages")
        } else {
            messages = []
            print("[MigrationService] ℹ️ chat_history.json not found or corrupt — creating empty thread")
        }

        do {
            let threadId = try await threadStore.createThread(
                title: Self.defaultThreadTitle,
                settings: ThreadSettings()
            )
            if !messages.isEmpty {
                try await threadStore.saveMessages(messages, toThreadId: threadId)
                print("[MigrationService] ✅ Chat history migrated to thread '\(Self.defaultThreadTitle)' (id: \(threadId))")
            } else {
                print("[MigrationService] ✅ Empty thread '\(Self.defaultThreadTitle)' created (id: \(threadId))")
            }
        } catch {
            print("[MigrationService] ❌ Thread creation failed: \(error)")
        }
    }

    /// Reads semantic.json and imports entries into MemoryStore (scope=global).
    private func migrateSemanticMemory(from url: URL) async {
        guard fileManager.fileExists(atPath: url.path) else {
            print("[MigrationService] ℹ️ semantic.json not found, skipping memory migration")
            return
        }

        guard let data = try? Data(contentsOf: url),
              let storage = try? JSONDecoder().decode([String: LegacyMemoryRecord].self, from: data),
              !storage.isEmpty else {
            print("[MigrationService] ℹ️ semantic.json is empty or corrupt, skipping")
            return
        }

        print("[MigrationService] 🧠 Migrating \(storage.count) memory entries from semantic.json...")

        let entries: [MemoryEntry] = storage.map { key, record in
            MemoryEntry(key: key, type: record.type, jsonString: record.data)
        }

        do {
            try await memoryStore.importEntries(entries, intoScope: "global")
            print("[MigrationService] ✅ \(entries.count) memory entries migrated (scope=global)")
        } catch {
            print("[MigrationService] ❌ Memory migration failed: \(error)")
        }
    }
}

// MARK: - LegacyMemoryRecord

/// Represents a record from the legacy semantic.json format.
/// Temporary type — only used during migration. Can be removed once semantic.json is fully retired.
private struct LegacyMemoryRecord: Codable {
    let type: String
    let timestamp: Date
    let data: String

    // Custom decoder: timestamp may be absent in old records written before it was introduced.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(String.self, forKey: .type)
        self.data = try container.decode(String.self, forKey: .data)
        self.timestamp = (try? container.decode(Date.self, forKey: .timestamp)) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(data, forKey: .data)
    }

    enum CodingKeys: String, CodingKey {
        case type, timestamp, data
    }
}
