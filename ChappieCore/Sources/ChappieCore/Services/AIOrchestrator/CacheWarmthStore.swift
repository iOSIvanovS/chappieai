// CacheWarmthStore.swift
// ChappieCore
//
// Where the "last request was at" mark for a thread is kept.
//
// WHY THIS EXISTS AT ALL:
// The wider cache allowance (3x the window) is only worth using while the provider still reads
// the prefix written by the previous turn. After a pause longer than the cache TTL that prefix is
// gone, so sending a long history protects nothing and only makes the next write bigger.
//
// WHY IT MUST SURVIVE A RESTART:
// Keeping the mark in memory alone costs a full prefix write on the first turn after every app
// launch. Measured on a 104-message history: 84079 tokens written, 23.64 RUB for one turn,
// against 2.29 RUB when the prefix is read. Restarting between turns is normal working practice,
// so that single turn is not an edge case — it is the common one.
//
// WHY A PROTOCOL, NOT USERDEFAULTS DIRECTLY IN THE ORCHESTRATOR:
// The orchestrator is an actor tested without a host app; a store it can be handed keeps the
// warmth logic testable and leaves the persistence choice outside the loop that runs on every
// request.

import Foundation

// MARK: - CacheWarmthStore

/// Remembers when each thread last sent a request.
///
/// Keyed by thread because the cached prefix belongs to one conversation: another thread's mark
/// says nothing about this one.
public protocol CacheWarmthStore: Sendable {

    /// The last request time recorded for this thread, or nil if none was ever recorded.
    func lastRequestAt(threadId: UUID?) -> Date?

    /// Records the request time for this thread. A nil date forgets it.
    func setLastRequestAt(_ date: Date?, threadId: UUID?)
}

// MARK: - InMemoryCacheWarmthStore

/// Keeps the mark for the lifetime of the process only. Used by tests and as the base for
/// callers that do not want persistence.
public final class InMemoryCacheWarmthStore: CacheWarmthStore, @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [UUID: Date] = [:]

    public init() {}

    public func lastRequestAt(threadId: UUID?) -> Date? {
        guard let key = Self.key(for: threadId) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    public func setLastRequestAt(_ date: Date?, threadId: UUID?) {
        guard let key = Self.key(for: threadId) else { return }
        lock.lock()
        defer { lock.unlock() }
        storage[key] = date
    }

    /// A thread-less call has no prefix of its own to protect, so it is never warm.
    static func key(for threadId: UUID?) -> UUID? { threadId }
}

// MARK: - UserDefaultsCacheWarmthStore

/// Persists the mark across launches in UserDefaults.
///
/// WHY NOT THE SQLITE STORE: the mark is worthless within a couple of hours and a wrong guess
/// costs one cache write, so it does not deserve a table, a migration, or a write per request.
/// UserDefaults is synchronous, thread-safe and costs microseconds.
///
/// One dictionary under one key, not one key per thread: entries are pruned on write, which needs
/// the whole set anyway, and this keeps a deleted thread's leftovers bounded.
public final class UserDefaultsCacheWarmthStore: CacheWarmthStore, @unchecked Sendable {

    /// Entries older than this are dropped on write. Well past any useful TTL, and short enough
    /// that deleted threads do not accumulate.
    static let retention: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "chappie.cacheWarmth.lastRequestAt") {
        self.defaults = defaults
        self.key = key
    }

    public func lastRequestAt(threadId: UUID?) -> Date? {
        guard let id = threadId?.uuidString else { return nil }
        guard let raw = defaults.dictionary(forKey: key)?[id] as? Double else { return nil }
        return Date(timeIntervalSince1970: raw)
    }

    public func setLastRequestAt(_ date: Date?, threadId: UUID?) {
        guard let id = threadId?.uuidString else { return }
        var stored = defaults.dictionary(forKey: key) ?? [:]

        if let date {
            stored[id] = date.timeIntervalSince1970
        } else {
            stored.removeValue(forKey: id)
        }

        let cutoff = Date().addingTimeInterval(-Self.retention).timeIntervalSince1970
        stored = stored.filter { _, value in
            guard let timestamp = value as? Double else { return false }
            return timestamp >= cutoff
        }

        defaults.set(stored, forKey: key)
    }
}
