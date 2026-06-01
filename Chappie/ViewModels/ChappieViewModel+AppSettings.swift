// ChappieViewModel+AppSettings.swift
// Chappie
//
// V2 integration: replaces three UserDefaults calls with New.AppSettingsStore.
// All methods are guarded by FeatureFlags.useThreadIsolationV2 —
// when flag is OFF the old UserDefaults path runs unchanged.

import Foundation
import SwiftData
import ChappieCore

extension ChappieViewModel {

    // MARK: - V2 Store

    /// Wires AppSettingsStore into the ViewModel after ModelContainer is ready.
    /// Called from setModelContainer(_:) when the V2 flag is active.
    func connectAppSettingsStore(container: ModelContainer) {
        guard FeatureFlags.useThreadIsolationV2 else { return }
        self.appSettingsStore = New.AppSettingsStore(modelContainer: container)
    }

    // MARK: - Balance Storage

    /// Saves provider balance — V2 path uses SwiftData, legacy path uses UserDefaults.
    func saveBalance(_ balance: Double, for providerId: UUID) {
        if FeatureFlags.useThreadIsolationV2, let store = appSettingsStore {
            Task { try? await store.save(balance: balance, for: providerId) }
        } else {
            UserDefaults.standard.set(balance, forKey: balanceKey(for: providerId))
        }
    }

    /// Loads provider balance synchronously from cache (V2) or UserDefaults (legacy).
    /// V2 cache is populated at startup by refreshBalanceCacheIfNeeded().
    func loadBalance(for providerId: UUID) -> Double? {
        if FeatureFlags.useThreadIsolationV2 && appSettingsStore != nil {
            return cachedBalances[providerId]
        } else {
            return UserDefaults.standard.object(forKey: balanceKey(for: providerId)) as? Double
        }
    }

    /// Refreshes the in-memory balance cache from SwiftData (V2 only).
    func refreshBalanceCacheIfNeeded() async {
        guard FeatureFlags.useThreadIsolationV2, let store = appSettingsStore else { return }
        if let balances = try? await store.loadBalances() {
            await MainActor.run { self.cachedBalances = balances }
        }
    }

    // MARK: - Last Active Thread

    /// Saves the last active thread ID — V2 uses SwiftData, legacy uses UserDefaults.
    func saveLastActiveThreadId(_ id: UUID) {
        if FeatureFlags.useThreadIsolationV2, let store = appSettingsStore {
            Task { try? await store.save(lastActiveThreadId: id) }
        } else {
            UserDefaults.standard.set(id.uuidString, forKey: lastActiveThreadIdKey)
        }
    }

    /// Loads last active thread ID synchronously from cache (V2) or UserDefaults (legacy).
    /// V2 cache is populated at startup by preloadLastActiveThreadId().
    func loadLastActiveThreadId() -> UUID? {
        if FeatureFlags.useThreadIsolationV2 && appSettingsStore != nil {
            return cachedLastActiveThreadId
        } else {
            guard let str = UserDefaults.standard.string(forKey: lastActiveThreadIdKey) else { return nil }
            return UUID(uuidString: str)
        }
    }

    /// Loads lastActiveThreadId from SwiftData into cache (V2 only).
    /// Called once during app startup, before thread selection.
    func preloadLastActiveThreadId() async {
        guard FeatureFlags.useThreadIsolationV2, let store = appSettingsStore else { return }
        if let id = try? await store.loadLastActiveThreadId() {
            await MainActor.run { self.cachedLastActiveThreadId = id }
        }
    }

    // MARK: - Workspace Bookmark

    /// Saves workspace security-scoped bookmark — V2 uses SwiftData, legacy uses UserDefaults.
    func saveWorkspaceBookmark(_ data: Data) {
        if FeatureFlags.useThreadIsolationV2, let store = appSettingsStore {
            Task { try? await store.save(workspaceBookmark: data) }
        } else {
            UserDefaults.standard.set(data, forKey: "workspaceBookmark")
        }
    }

    /// Loads workspace bookmark data — V2 uses SwiftData, legacy uses UserDefaults.
    func loadWorkspaceBookmarkData() async -> Data? {
        if FeatureFlags.useThreadIsolationV2, let store = appSettingsStore {
            return try? await store.loadWorkspaceBookmark()
        } else {
            return UserDefaults.standard.data(forKey: "workspaceBookmark")
        }
    }
}
