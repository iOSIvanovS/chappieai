// ChappieViewModel+AppSettings.swift
// Chappie
//
// App settings: balance, last active thread, workspace bookmark.
// All state is persisted via AppSettingsStore → ChappieDataStore. No UserDefaults.

import Foundation
import ChappieCore

extension ChappieViewModel {

    // MARK: - Balance Storage

    func saveBalance(_ balance: Double, for providerId: UUID) {
        guard let store = appSettingsStore else { return }
        Task { try? await store.save(balance: balance, for: providerId) }
    }

    func loadBalance(for providerId: UUID) -> Double? {
        cachedBalances[providerId]
    }

    func refreshBalanceCacheIfNeeded() async {
        guard let store = appSettingsStore else { return }
        if let balances = try? await store.loadBalances() {
            await MainActor.run { self.cachedBalances = balances }
        }
    }

    // MARK: - Last Active Thread

    func saveLastActiveThreadId(_ id: UUID) {
        guard let store = appSettingsStore else { return }
        Task { try? await store.save(lastActiveThreadId: id) }
    }

    func loadLastActiveThreadId() -> UUID? {
        cachedLastActiveThreadId
    }

    func preloadLastActiveThreadId() async {
        guard let store = appSettingsStore else { return }
        if let id = try? await store.loadLastActiveThreadId() {
            await MainActor.run { self.cachedLastActiveThreadId = id }
        }
    }

    // MARK: - Workspace Bookmark

    func saveWorkspaceBookmark(_ data: Data) {
        guard let store = appSettingsStore else { return }
        Task { try? await store.save(workspaceBookmark: data) }
    }

    func loadWorkspaceBookmarkData() async -> Data? {
        guard let store = appSettingsStore else { return nil }
        return try? await store.loadWorkspaceBookmark()
    }
}
