// SQLiteStorage.swift
// ChappieCore
//
// Production SQLite backend via GRDB.
//
// SCHEMA:
// Single table `stored_records` with two columns:
//   relation TEXT PRIMARY KEY  — the ChappieStorageRelation.key string
//   payload  BLOB NOT NULL     — JSON-encoded domain data
//
// WHY ONE TABLE:
// Our access pattern is always key→blob. No joins, no filtering by payload content.
// One table keeps the schema trivial and migrations rare.
//
// WHY DatabaseWriter (not DatabasePool directly):
// DatabasePool doesn't support :memory: paths — it requires a real file.
// Tests use DatabaseQueue (in-memory), production uses DatabasePool (WAL mode).
// Both conform to DatabaseWriter + DatabaseReader, so the actor works identically.

import Foundation
import GRDB

// MARK: - StoredRow

/// Raw GRDB record mapping to the `stored_records` table.
private struct StoredRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "stored_records"

    var relation: String
    var payload: Data
}

// MARK: - SQLiteStorage

/// Production persistence backend backed by SQLite via GRDB.
/// Conforms to ChappieStorage — drop-in replacement for ChappieDataStore.
public actor SQLiteStorage: ChappieStorage {

    // MARK: - Properties

    // DatabaseWriter covers both DatabasePool (file) and DatabaseQueue (in-memory).
    private let db: any DatabaseWriter

    // MARK: - Init (production — file-based DatabasePool with WAL)

    /// Creates or opens the SQLite database at the given URL.
    /// Uses DatabasePool with WAL for concurrent reads. Runs schema migrations on init.
    public init(url: URL) throws {
        var config = Configuration()
        // WAL mode — allows concurrent reads while writing.
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        try SQLiteStorage.runMigrations(pool)
        self.db = pool
    }

    // MARK: - Init (testing — in-memory DatabaseQueue)

    /// Creates an isolated in-memory database. Used exclusively in tests.
    /// DatabasePool doesn't support :memory: — DatabaseQueue does.
    public init(inMemory: Bool = false) throws {
        precondition(inMemory, "Use init(url:) for file-based storage")
        let queue = try DatabaseQueue()
        try SQLiteStorage.runMigrations(queue)
        self.db = queue
    }

    // MARK: - Migration

    private static func runMigrations(_ writer: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_stored_records") { db in
            try db.create(table: "stored_records", ifNotExists: true) { t in
                t.column("relation", .text).primaryKey()
                t.column("payload", .blob).notNull()
            }
        }

        try migrator.migrate(writer)
    }

    // MARK: - ChappieStorage: Read

    public func load<T: Codable & Sendable>(_ relation: ChappieStorageRelation) async throws -> T? {
        guard let data = try await loadRawData(relation) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // Callers treat nil as "use defaults" and will overwrite the record on the next save,
            // so keep a copy of the unreadable bytes first. Nothing is lost silently.
            print("[SQLiteStorage] ⚠️ Decode failed for '\(relation.key)': \(error)")
            do {
                let backupKey = try await preserveCorruptedRecord(key: relation.key, data: data)
                print("[SQLiteStorage] 🛟 Unreadable record preserved as '\(backupKey)'")
            } catch {
                print("[SQLiteStorage] ❌ Could not preserve unreadable '\(relation.key)': \(error)")
            }
            return nil
        }
    }

    public func loadRawData(_ relation: ChappieStorageRelation) async throws -> Data? {
        let key = relation.key
        return try await db.read { db in
            try StoredRow
                .filter(Column("relation") == key)
                .fetchOne(db)?
                .payload
        }
    }

    // MARK: - ChappieStorage: Write

    public func save<T: Codable & Sendable>(_ value: T, for relation: ChappieStorageRelation) async throws {
        let data = try JSONEncoder().encode(value)
        try await saveRawData(data, for: relation)
    }

    public func saveRawData(_ data: Data, for relation: ChappieStorageRelation) async throws {
        let row = StoredRow(relation: relation.key, payload: data)
        try await db.write { db in
            // INSERT OR REPLACE — upsert without separate SELECT
            try row.save(db)
        }
    }

    // MARK: - ChappieStorage: Delete

    public func delete(_ relation: ChappieStorageRelation) async throws {
        let key = relation.key
        _ = try await db.write { db in
            try StoredRow
                .filter(Column("relation") == key)
                .deleteAll(db)
        }
        print("[SQLiteStorage] 🗑 Deleted relation '\(key)'")
    }

    /// Deletes all rows whose key starts with prefix — atomically in one transaction.
    /// Used to delete all chunks of a thread at once.
    public func deleteByPrefix(_ prefix: String) async throws {
        _ = try await db.write { db in
            try StoredRow
                .filter(Column("relation").like("\(prefix)%"))
                .deleteAll(db)
        }
        print("[SQLiteStorage] 🗑 Deleted all rows with prefix '\(prefix)'")
    }

    /// Delete-tail + insert in a single transaction. The suffix is parsed inside the transaction
    /// so a concurrent writer cannot slip a new row between our read and our delete.
    public func replaceIndexedRecords(prefix: String, fromIndex: Int, payloads: [Data]) async throws {
        _ = try await db.write { db in
            let existing = try StoredRow
                .filter(Column("relation").like("\(prefix)%"))
                .fetchAll(db)
            for row in existing {
                let suffix = row.relation.dropFirst(prefix.count)
                if let index = Int(suffix), index >= fromIndex {
                    try StoredRow
                        .filter(Column("relation") == row.relation)
                        .deleteAll(db)
                }
            }
            for (offset, data) in payloads.enumerated() {
                try StoredRow(relation: "\(prefix)\(fromIndex + offset)", payload: data).save(db)
            }
        }
    }

    public func preserveCorruptedRecord(key: String, data: Data) async throws -> String {
        let prefix = "\(key).corrupt."
        return try await db.write { db in
            let existing = try StoredRow
                .filter(Column("relation").like("\(prefix)%"))
                .fetchAll(db)
            if let same = existing.first(where: { $0.payload == data }) {
                return same.relation
            }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            let base = prefix + formatter.string(from: Date())

            // Two different corrupt blobs in the same second must not overwrite each other.
            let taken = Set(existing.map(\.relation))
            var name = base
            var counter = 1
            while taken.contains(name) {
                counter += 1
                name = "\(base)-\(counter)"
            }
            try StoredRow(relation: name, payload: data).save(db)
            return name
        }
    }

    // MARK: - ChappieStorage: Existence

    public func exists(_ relation: ChappieStorageRelation) async throws -> Bool {
        let key = relation.key
        return try await db.read { db in
            try StoredRow
                .filter(Column("relation") == key)
                .fetchCount(db) > 0
        }
    }

    // MARK: - ChappieStorage: Enumeration

    /// Returns all keys starting with prefix, sorted ascending.
    /// Chunk keys sort correctly by index because we zero-pad to 6 digits.
    public func keys(withPrefix prefix: String) async throws -> [String] {
        return try await db.read { db in
            let rows = try StoredRow
                .filter(Column("relation").like("\(prefix)%"))
                .order(Column("relation").asc)
                .fetchAll(db)
            return rows.map { $0.relation }
        }
    }
}

// MARK: - Default path

public extension SQLiteStorage {

    /// Standard database location: ~/Library/Application Support/ChappieAI/chappie.db
    static var defaultURL: URL {
        get throws {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dir = appSupport.appendingPathComponent("ChappieAI", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("chappie.db")
        }
    }
}
