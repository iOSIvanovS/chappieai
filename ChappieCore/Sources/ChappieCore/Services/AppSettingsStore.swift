// AppSettingsStore.swift
// ChappieCore
//
// Actor-based store for app-wide settings via ChappieDataStore.
// No SwiftData imports here — all persistence goes through ChappieDataStore.Relation.appSettings.
//
// SINGLETON RECORD PATTERN:
// Exactly one AppSettingsPayload is stored per app installation.
// load() returns it or creates a fresh default on first call.
//
// CODABLE COMPATIBILITY (see DataStore.swift for full rules):
//   1. Never rename AppSettingsPayload fields without CodingKeys.
//   2. Never remove fields — mark optional with a default instead.
//   3. New fields must have a default value so old records decode cleanly.

import Foundation

// MARK: - AppSettingsPayload

/// The Codable struct stored under ChappieDataStore.Relation.appSettings.
/// Replaces the legacy @Model AppSettings class.
///
/// WHY STRUCT, NOT @MODEL: plain Codable — no SwiftData migrations ever needed.
/// All fields have defaults so old stored records always decode cleanly.
public struct AppSettingsPayload: Codable, Sendable {

    /// Security-scoped bookmark for the workspace folder.
    public var workspaceBookmark: Data?

    /// UUID of the thread that was active when the app was last closed.
    public var lastActiveThreadId: UUID?

    /// Provider balances: [providerUUID: balance].
    public var balances: [String: Double]

    public init(
        workspaceBookmark: Data? = nil,
        lastActiveThreadId: UUID? = nil,
        balances: [String: Double] = [:]
    ) {
        self.workspaceBookmark = workspaceBookmark
        self.lastActiveThreadId = lastActiveThreadId
        self.balances = balances
    }

    // CodingKeys guard against future renames.
    private enum CodingKeys: String, CodingKey {
        case workspaceBookmark  = "workspace_bookmark"
        case lastActiveThreadId = "last_active_thread_id"
        case balances
    }
}

// MARK: - AppSettingsStore

/// Actor for reading and writing app-wide settings via ChappieDataStore.
public actor AppSettingsStore {

    private let dataStore: ChappieDataStore

    public init(dataStore: ChappieDataStore) {
        self.dataStore = dataStore
    }

    // MARK: - Private helpers

    /// Loads current payload or returns a fresh default.
    private func loadPayload() async throws -> AppSettingsPayload {
        return (try await dataStore.load(.appSettings)) ?? AppSettingsPayload()
    }

    private func savePayload(_ payload: AppSettingsPayload) async throws {
        try await dataStore.save(payload, for: .appSettings)
    }

    // MARK: - Full load / save

    /// Returns the full settings payload.
    public func load() async throws -> AppSettingsPayload {
        return try await loadPayload()
    }

    /// Saves the full settings payload.
    public func save(_ payload: AppSettingsPayload) async throws {
        try await savePayload(payload)
    }

    // MARK: - Workspace Bookmark

    public func save(workspaceBookmark: Data?) async throws {
        var payload = try await loadPayload()
        payload.workspaceBookmark = workspaceBookmark
        try await savePayload(payload)
    }

    public func loadWorkspaceBookmark() async throws -> Data? {
        return try await loadPayload().workspaceBookmark
    }

    // MARK: - Last Active Thread

    public func save(lastActiveThreadId: UUID?) async throws {
        var payload = try await loadPayload()
        payload.lastActiveThreadId = lastActiveThreadId
        try await savePayload(payload)
    }

    public func loadLastActiveThreadId() async throws -> UUID? {
        return try await loadPayload().lastActiveThreadId
    }

    // MARK: - Provider Balances

    /// Saves a balance for a specific provider UUID. Pass nil to remove the entry.
    public func save(balance: Double?, for providerID: UUID) async throws {
        var payload = try await loadPayload()
        if let value = balance {
            payload.balances[providerID.uuidString] = value
        } else {
            payload.balances.removeValue(forKey: providerID.uuidString)
        }
        try await savePayload(payload)
    }

    /// Returns all stored balances as [providerUUID: balance].
    public func loadBalances() async throws -> [UUID: Double] {
        let raw = try await loadPayload().balances
        return Dictionary(
            uniqueKeysWithValues: raw.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            }
        )
    }
}
