// AppSettingsStore.swift
// ChappieCore
//
// Actor-based store for app-wide settings via ChappieStorage protocol.
//
// SINGLETON RECORD PATTERN:
// Exactly one AppSettingsPayload is stored per app installation.
// load() returns it or creates a fresh default on first call.

import Foundation

// MARK: - AppSettingsPayload

/// The Codable struct stored under .appSettings relation.
/// All fields have defaults so old stored records always decode cleanly.
public struct AppSettingsPayload: Codable, Sendable {

    public var workspaceBookmark: Data?
    public var lastActiveThreadId: UUID?
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

    private enum CodingKeys: String, CodingKey {
        case workspaceBookmark  = "workspace_bookmark"
        case lastActiveThreadId = "last_active_thread_id"
        case balances
    }
}

// MARK: - AppSettingsStore

public actor AppSettingsStore {

    private let dataStore: any ChappieStorage

    public init(dataStore: any ChappieStorage) {
        self.dataStore = dataStore
    }

    // MARK: - Private helpers

    private func loadPayload() async throws -> AppSettingsPayload {
        return (try await dataStore.load(.appSettings)) ?? AppSettingsPayload()
    }

    private func savePayload(_ payload: AppSettingsPayload) async throws {
        try await dataStore.save(payload, for: .appSettings)
    }

    // MARK: - Full load / save

    public func load() async throws -> AppSettingsPayload {
        return try await loadPayload()
    }

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

    public func save(balance: Double?, for providerID: UUID) async throws {
        var payload = try await loadPayload()
        if let value = balance {
            payload.balances[providerID.uuidString] = value
        } else {
            payload.balances.removeValue(forKey: providerID.uuidString)
        }
        try await savePayload(payload)
    }

    public func loadBalances() async throws -> [UUID: Double] {
        let raw = try await loadPayload().balances
        return Dictionary(
            uniqueKeysWithValues: raw.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            }
        )
    }
}
