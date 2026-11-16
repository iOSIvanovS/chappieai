// ContextWindowStateStoreTests.swift
// ChappieCoreTests
//
// The state exists so a relaunch between turns does not throw away a warm prefix — measured as
// 23.64 RUB against 2.29 RUB for the same turn — and so the window stands still instead of
// sliding. These tests pin the properties that make it worth anything: it survives a new store
// instance, it is per thread, and the anchor signature is stable across processes.

import Foundation
import Testing
@testable import ChappieCore

@Suite("Context window state store")
struct ContextWindowStateStoreTests {

    /// A suite of its own per store, so parallel tests never share state in UserDefaults.
    private func isolatedDefaults() -> UserDefaults {
        let name = "chappie.tests.windowState.\(UUID().uuidString)"
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

        UserDefaultsContextWindowStateStore(defaults: defaults).setLastRequestAt(sent, threadId: threadId)

        // A second instance stands in for the app relaunching.
        let afterRelaunch = UserDefaultsContextWindowStateStore(defaults: defaults)
        let restored = afterRelaunch.lastRequestAt(threadId: threadId)
        #expect(restored?.timeIntervalSince1970 == sent.timeIntervalSince1970)
    }

    @Test("An anchor written by one store is read by a newly created one")
    func anchorSurvivesNewInstance() {
        let defaults = isolatedDefaults()
        let threadId = UUID()

        UserDefaultsContextWindowStateStore(defaults: defaults)
            .setAnchorSignature("user:12345", threadId: threadId)

        let afterRelaunch = UserDefaultsContextWindowStateStore(defaults: defaults)
        #expect(afterRelaunch.anchorSignature(threadId: threadId) == "user:12345")
    }

    @Test("Nothing recorded means no mark and no anchor")
    func emptyByDefault() {
        let store = UserDefaultsContextWindowStateStore(defaults: isolatedDefaults())
        #expect(store.lastRequestAt(threadId: UUID()) == nil)
        #expect(store.lastRequestAt(threadId: nil) == nil, "a thread-less turn has no prefix to warm")
        #expect(store.anchorSignature(threadId: UUID()) == nil)
        #expect(store.anchorSignature(threadId: nil) == nil)
    }

    // MARK: - Per thread

    @Test("Threads do not see each other's marks")
    func isolatedPerThread() {
        let store = UserDefaultsContextWindowStateStore(defaults: isolatedDefaults())
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

    @Test("Threads do not see each other's anchors")
    func anchorsIsolatedPerThread() {
        let store = UserDefaultsContextWindowStateStore(defaults: isolatedDefaults())
        let first = UUID()
        let second = UUID()

        store.setAnchorSignature("user:aaa", threadId: first)
        store.setAnchorSignature("assistant:bbb", threadId: second)

        #expect(store.anchorSignature(threadId: first) == "user:aaa")
        #expect(store.anchorSignature(threadId: second) == "assistant:bbb")
    }

    @Test("A nil value forgets the entry")
    func clearRemovesEntry() {
        let store = UserDefaultsContextWindowStateStore(defaults: isolatedDefaults())
        let threadId = UUID()
        store.setLastRequestAt(Date(), threadId: threadId)
        store.setAnchorSignature("user:1", threadId: threadId)

        store.setLastRequestAt(nil, threadId: threadId)
        store.setAnchorSignature(nil, threadId: threadId)

        #expect(store.lastRequestAt(threadId: threadId) == nil)
        #expect(store.anchorSignature(threadId: threadId) == nil)
    }

    // MARK: - Pruning

    @Test("A write prunes entries older than the retention window and keeps fresh ones")
    func prunesStaleEntries() {
        let defaults = isolatedDefaults()
        let stale = UUID()
        let fresh = UUID()

        // Written straight into the backing store, because a normal write would prune it at once.
        let old = Date().addingTimeInterval(-UserDefaultsContextWindowStateStore.retention - 3600)
        defaults.set([stale.uuidString: old.timeIntervalSince1970], forKey: "chappie.tests.injected")

        let injected = UserDefaultsContextWindowStateStore(
            defaults: defaults,
            timeKey: "chappie.tests.injected"
        )
        #expect(injected.lastRequestAt(threadId: stale) != nil, "an old entry stays readable until a write")

        // Any write prunes the whole set, which is why pruning happens here and not on every read.
        injected.setLastRequestAt(Date(), threadId: fresh)

        #expect(injected.lastRequestAt(threadId: stale) == nil)
        #expect(injected.lastRequestAt(threadId: fresh) != nil)
    }

    // MARK: - In-memory store

    @Test("The in-memory store keeps state for the life of the process")
    func inMemoryStore() {
        let store = InMemoryContextWindowStateStore()
        let threadId = UUID()
        #expect(store.lastRequestAt(threadId: threadId) == nil)
        #expect(store.anchorSignature(threadId: threadId) == nil)

        store.setLastRequestAt(Date(), threadId: threadId)
        store.setAnchorSignature("user:7", threadId: threadId)
        #expect(store.lastRequestAt(threadId: threadId) != nil)
        #expect(store.anchorSignature(threadId: threadId) == "user:7")

        store.setLastRequestAt(nil, threadId: threadId)
        store.setAnchorSignature(nil, threadId: threadId)
        #expect(store.lastRequestAt(threadId: threadId) == nil)
        #expect(store.anchorSignature(threadId: threadId) == nil)
    }

    // MARK: - Anchor signatures

    // A signature must be identical in every process: Swift's own hashing is seeded per launch, so
    // an anchor written before a relaunch would never be found after one.

    @Test("The same message always yields the same signature")
    func signatureIsStable() {
        let message = AIMessage(role: "user", content: "hello")
        #expect(WindowAnchor.signature(of: message) == WindowAnchor.signature(of: message))
    }

    @Test("Role and text both take part in the signature")
    func signatureSeparatesRoleAndText() {
        let userHello = AIMessage(role: "user", content: "hello")
        let assistantHello = AIMessage(role: "assistant", content: "hello")
        let userOther = AIMessage(role: "user", content: "hello!")

        #expect(WindowAnchor.signature(of: userHello) != WindowAnchor.signature(of: assistantHello))
        #expect(WindowAnchor.signature(of: userHello) != WindowAnchor.signature(of: userOther))
    }

    @Test("FNV-1a matches the published constants, so a relaunch finds the anchor again")
    func fnvKnownValues() {
        // Reference values for FNV-1a 64-bit; a change here would silently break anchors across
        // launches, which no other test would notice.
        #expect(WindowAnchor.fnv1a("") == 0xcbf2_9ce4_8422_2325)
        #expect(WindowAnchor.fnv1a("a") == 0xaf63_dc4c_8601_ec8c)
        #expect(WindowAnchor.fnv1a("hello") == 0xa430_d846_80aa_bd0b)
    }
}
