// ChappieViewModel+AppSettings.swift
// Chappie
//
// SwiftData-backed app settings — balance, last active thread, workspace bookmark.
// All state is persisted via AppSettingsStore (SwiftData), no UserDefaults.

import Foundation
import SwiftData
import ChappieCore

extension ChappieViewModel {

    // MARK: - Store

    /// Wires AppSettingsStore into the ViewModel after ModelContainer is ready.
    /// Called from setModelContainer(_:).
    func connectAppSettingsStore(container: ModelContainer) {
        self.appSettingsStore = AppSettingsStore(modelContainer: container)
    }

    // MARK: - Balance Storage

    /// Saves provider balance to SwiftData via AppSettingsStore.
    func saveBalance(_ balance: Double, for providerId: UUID) {
        guard let store = appSettingsStore else { return }
        Task { try? await store.save(balance: balance, for: providerId) }
    }

    /// Loads provider balance synchronously from in-memory cache.
    /// Cache is populated at startup by refreshBalanceCacheIfNeeded().
    func loadBalance(for providerId: UUID) -> Double? {
        cachedBalances[providerId]
    }

    /// Refreshes the in-memory balance cache from SwiftData.
    func refreshBalanceCacheIfNeeded() async {
        guard let store = appSettingsStore else { return }
        if let balances = try? await store.loadBalances() {
            await MainActor.run { self.cachedBalances = balances }
        }
    }

    // MARK: - Last Active Thread

    /// Saves the last active thread ID to SwiftData.
    func saveLastActiveThreadId(_ id: UUID) {
        guard let store = appSettingsStore else { return }
        Task { try? await store.save(lastActiveThreadId: id) }
    }

    /// Loads last active thread ID synchronously from in-memory cache.
    /// Cache is populated at startup by preloadLastActiveThreadId().
    func loadLastActiveThreadId() -> UUID? {
        cachedLastActiveThreadId
    }

    /// Loads lastActiveThreadId from SwiftData into cache.
    /// Called once during app startup, before thread selection.
    func preloadLastActiveThreadId() async {
        guard let store = appSettingsStore else { return }
        if let id = try? await store.loadLastActiveThreadId() {
            await MainActor.run { self.cachedLastActiveThreadId = id }
        }
    }

    // MARK: - Workspace Bookmark

    /// Saves workspace security-scoped bookmark to SwiftData.
    func saveWorkspaceBookmark(_ data: Data) {
        guard let store = appSettingsStore else { return }
        Task { try? await store.save(workspaceBookmark: data) }
    }

    /// Loads workspace bookmark data from SwiftData.
    func loadWorkspaceBookmarkData() async -> Data? {
        guard let store = appSettingsStore else { return nil }
        return try? await store.loadWorkspaceBookmark()
    }
}
