// CacheWarmthStoreTests.swift
// ChappieCoreTests
//
// The mark exists so a relaunch between turns does not throw away a warm prefix — measured as
// 23.64 RUB against 2.29 RUB for the same turn. These tests pin the two properties that make it
// worth anything: it survives a new store instance, and it is per thread.

import Foundation
import Testing
@testable import ChappieCore

@Suite("Cache warmth store")
struct CacheWarmthStoreTests {

    /// A suite of its own per store, so parallel tests never share state in UserDefaults.
    private func isolatedDefaults() -> UserDefaults {
        let name = "chappie.tests.cacheWarmth.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - Persistence

    @Test("A mark written by one store is read by a newly created one")
    func survivesNewInstance() {
        let defaults = isolatedDefaults()
        let threadId = UUID()
        // Recent, because a write prunes anything older than the retention window.
        let sent = Date().addingTimeInterval(-60)

        UserDefaultsCacheWarmthStore(defaults: defaults).setLastRequestAt(sent, threadId: threadId)

        // A second instance stands in for the app relaunching.
        let afterRelaunch = UserDefaultsCacheWarmthStore(defaults: defaults)
        let restored = afterRelaunch.lastRequestAt(threadId: threadId)
        #expect(restored?.timeIntervalSince1970 == sent.timeIntervalSince1970)
    }

    @Test("Nothing recorded means no mark")
    func emptyByDefault() {
        let store = UserDefaultsCacheWarmthStore(defaults: isolatedDefaults())
        #expect(store.lastRequestAt(threadId: UUID()) == nil)
        #expect(store.lastRequestAt(threadId: nil) == nil, "a thread-less turn has no prefix to warm")
    }

    // MARK: - Per thread

    @Test("Threads do not see each other's marks")
    func isolatedPerThread() {
        let store = UserDefaultsCacheWarmthStore(defaults: isolatedDefaults())
        let first = UUID()
        let second = UUID()
        // Both recent: an old date would be pruned by the second write, not by the per-thread split.
        let firstTime = Date().addingTimeInterval(-120)
        let secondTime = Date().addingTimeInterval(-60)

        store.setLastRequestAt(firstTime, threadId: first)
        store.setLastRequestAt(secondTime, threadId: second)

        #expect(store.lastRequestAt(threadId: first)?.timeIntervalSince1970 == firstTime.timeIntervalSince1970)
        #expect(store.lastRequestAt(threadId: second)?.timeIntervalSince1970 == secondTime.timeIntervalSince1970)
    }

    @Test("A nil date forgets the mark")
    func clearRemovesEntry() {
        let store = UserDefaultsCacheWarmthStore(defaults: isolatedDefaults())
        let threadId = UUID()
        store.setLastRequestAt(Date(), threadId: threadId)
        store.setLastRequestAt(nil, threadId: threadId)
        #expect(store.lastRequestAt(threadId: threadId) == nil)
    }

    // MARK: - Pruning

    @Test("A write prunes entries older than the retention window and keeps fresh ones")
    func prunesStaleEntries() {
        let defaults = isolatedDefaults()
        let store = UserDefaultsCacheWarmthStore(defaults: defaults)
        let stale = UUID()
        let fresh = UUID()

        // Written straight into the backing store, because a normal write would prune it at once.
        let old = Date().addingTimeInterval(-UserDefaultsCacheWarmthStore.retention - 3600)
        defaults.set([stale.uuidString: old.timeIntervalSince1970], forKey: "chappie.tests.injected")

        let injected = UserDefaultsCacheWarmthStore(defaults: defaults, key: "chappie.tests.injected")
        #expect(injected.lastRequestAt(threadId: stale) != nil, "an old entry stays readable until a write")

        // Any write prunes the whole set, which is why pruning happens here and not on every read.
        injected.setLastRequestAt(Date(), threadId: fresh)

        #expect(injected.lastRequestAt(threadId: stale) == nil)
        #expect(injected.lastRequestAt(threadId: fresh) != nil)
    }

    // MARK: - In-memory store

    @Test("The in-memory store keeps marks for the life of the process")
    func inMemoryStore() {
        let store = InMemoryCacheWarmthStore()
        let threadId = UUID()
        #expect(store.lastRequestAt(threadId: threadId) == nil)
        store.setLastRequestAt(Date(), threadId: threadId)
        #expect(store.lastRequestAt(threadId: threadId) != nil)
        store.setLastRequestAt(nil, threadId: threadId)
        #expect(store.lastRequestAt(threadId: threadId) == nil)
    }
}
