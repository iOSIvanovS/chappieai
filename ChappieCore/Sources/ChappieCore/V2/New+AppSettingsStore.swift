// New+AppSettingsStore.swift
// ChappieCore / V2
//
// Actor-based store for New.AppSettings — the single SwiftData record
// that replaces three UserDefaults keys in V2.
//
// SINGLETON RECORD PATTERN:
// The container holds exactly one AppSettings row.
// load() fetches it or creates one on first call.
// All write methods fetch the same record and mutate it in place.
//
// NOT YET WIRED to ChappieViewModel — this is a pure model layer.
// ViewModel integration happens in the next step.

import Foundation
import SwiftData

extension New {

    public actor AppSettingsStore {

        // MARK: - Dependencies

        private let modelContainer: ModelContainer

        // MARK: - Init

        public init(modelContainer: ModelContainer) {
            self.modelContainer = modelContainer
        }

        // MARK: - Load / Upsert

        /// Returns the single AppSettings record, creating it if absent.
        public func load() throws -> New.AppSettings {
            let context = ModelContext(modelContainer)
            let existing = try context.fetch(FetchDescriptor<New.AppSettings>())

            if let record = existing.first {
                return record
            }

            // First launch — insert a blank record
            let fresh = New.AppSettings()
            context.insert(fresh)
            try context.save()
            return fresh
        }

        // MARK: - Workspace Bookmark

        /// Persists a new security-scoped workspace bookmark.
        public func save(workspaceBookmark: Data?) throws {
            let context = ModelContext(modelContainer)
            let record = try fetchOrCreate(in: context)
            record.workspaceBookmark = workspaceBookmark
            try context.save()
        }

        /// Returns the stored workspace bookmark, or nil if not set.
        public func loadWorkspaceBookmark() throws -> Data? {
            let context = ModelContext(modelContainer)
            return try fetchOrCreate(in: context).workspaceBookmark
        }

        // MARK: - Last Active Thread

        /// Persists the UUID of the last active thread.
        public func save(lastActiveThreadId: UUID?) throws {
            let context = ModelContext(modelContainer)
            let record = try fetchOrCreate(in: context)
            record.lastActiveThreadId = lastActiveThreadId
            try context.save()
        }

        /// Returns the UUID of the last active thread, or nil if not set.
        public func loadLastActiveThreadId() throws -> UUID? {
            let context = ModelContext(modelContainer)
            return try fetchOrCreate(in: context).lastActiveThreadId
        }

        // MARK: - Provider Balances

        /// Saves a balance value for a specific provider UUID.
        /// Pass nil to remove the entry for that provider.
        public func save(balance: Double?, for providerID: UUID) throws {
            let context = ModelContext(modelContainer)
            let record = try fetchOrCreate(in: context)
            var dict = record.balances
            if let value = balance {
                dict[providerID.uuidString] = value
            } else {
                dict.removeValue(forKey: providerID.uuidString)
            }
            record.balances = dict
            try context.save()
        }

        /// Returns all stored provider balances as [providerUUID: balance].
        public func loadBalances() throws -> [UUID: Double] {
            let context = ModelContext(modelContainer)
            let raw = try fetchOrCreate(in: context).balances
            // Convert String keys back to UUID — drop malformed entries silently
            return Dictionary(
                uniqueKeysWithValues: raw.compactMap { key, value in
                    UUID(uuidString: key).map { ($0, value) }
                }
            )
        }

        // MARK: - Private helpers

        /// Fetches the single AppSettings record or inserts a blank one.
        /// All write methods call this instead of duplicating fetch logic.
        private func fetchOrCreate(in context: ModelContext) throws -> New.AppSettings {
            let existing = try context.fetch(FetchDescriptor<New.AppSettings>())
            if let record = existing.first { return record }
            let fresh = New.AppSettings()
            context.insert(fresh)
            try context.save()
            return fresh
        }
    }
}
