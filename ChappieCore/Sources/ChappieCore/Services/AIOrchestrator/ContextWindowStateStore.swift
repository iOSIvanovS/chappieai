// ContextWindowStateStore.swift
// ChappieCore
//
// Two facts the context window needs to remember between turns, per thread:
//   - when the last request went out, so a cold cache is recognised after a pause;
//   - where the window started last time, so it stands still instead of sliding.
//
// WHY THE ANCHOR MATTERS (measured, not theoretical):
// The caller hands in the whole loaded history, which grows by a couple of messages every turn.
// Cutting purely on its length gives a sliding window — 112 → newest 30, then 114 → newest 30 —
// where the first message of the window moves two places every turn. The provider's prefix cache
// matches from the very first message, so it dies immediately: live log at 18:55 and 19:39 shows
// two full prefix writes of ~84000 tokens, 23.86 RUB per turn against 2.29 RUB for a read.
//
// WHY THE ANCHOR IS A MESSAGE SIGNATURE, NOT AN INDEX:
// The app prepends older history chunks on demand (`ensureModelHistoryLoaded`), so every index in
// the array moves by an unpredictable amount between turns. An index anchor would point at a
// different message after every chunk load. A signature survives prepends: it is looked up in
// the current array, whatever its offset.
//
// WHY IT MUST SURVIVE A RESTART:
// The mark is only worth anything if the first turn after a relaunch knows the cache is warm.
// Keeping it in memory alone costs a full prefix write per launch (measured: 23.64 RUB).
//
// WHY A PROTOCOL, NOT USERDEFAULTS DIRECTLY IN THE ORCHESTRATOR:
// The orchestrator is an actor tested without a host app; a store it can be handed keeps this
// logic testable and leaves the persistence choice outside the loop that runs on every request.

import Foundation

// MARK: - WindowAnchor

/// Identifies the first message of a window in a way that survives prepending older history.
///
/// WHY NOT `hashValue`: Swift seeds its hasher per process, so a value written before a relaunch
/// would never be found after one. FNV-1a is a fixed formula, stable across processes and builds.
public enum WindowAnchor {

    /// Role plus a stable 64-bit hash of the content, as a string ready for UserDefaults.
    ///
    /// Use this only for a message whose position is unknown; `signatures(for:)` is what the
    /// window policy compares, because it disambiguates repeated text.
    public static func signature(of message: AIMessage) -> String {
        baseSignature(message)
    }

    /// Role plus content hash, before any copy number is added.
    static func baseSignature(_ message: AIMessage) -> String {
        "\(message.role):\(fnv1a(message.contentString ?? ""))"
    }

    /// Signatures for a whole history, each unique within it: role, content hash, and which copy
    /// of that same role-and-text it is.
    ///
    /// WHY THE COPY NUMBER IS NEEDED: a plain role-and-text signature is ambiguous whenever a
    /// conversation repeats itself — an assistant answering "ok" twenty times is ordinary, and so
    /// are two identical file reads. Matching such a signature by earliest copy slides the window
    /// forward every turn; by latest copy it slides too. Both bring back exactly the per-turn
    /// prefix rewrite the anchor exists to stop.
    ///
    /// Appending messages never renumbers anything that already existed, which is the case between
    /// two turns. Prepending an older chunk can renumber duplicates, which costs one re-cut and
    /// then settles — a bounded wrong case, unlike a window that slides every turn.
    public static func signatures(for history: [AIMessage]) -> [String] {
        var seen: [String: Int] = [:]
        return history.map { message in
            let base = baseSignature(message)
            let copy = seen[base, default: 0]
            seen[base] = copy + 1
            return copy == 0 ? base : "\(base)#\(copy)"
        }
    }

    /// FNV-1a over the UTF-8 bytes. Small, allocation-free and identical in every process.
    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }
}

// MARK: - ContextWindowStateStore

/// Remembers the window state of each thread: last request time, window anchor and the
/// fingerprint of the prefix that request carried.
///
/// Keyed by thread because the cached prefix belongs to one conversation: another thread's mark
/// says nothing about this one.
public protocol ContextWindowStateStore: Sendable {

    /// The last request time recorded for this thread, or nil if none was ever recorded.
    func lastRequestAt(threadId: UUID?) -> Date?

    /// Records the request time for this thread. A nil date forgets it.
    func setLastRequestAt(_ date: Date?, threadId: UUID?)

    /// Signature of the first message of the window sent last turn, or nil if unknown.
    /// See `WindowAnchor.signature(of:)`.
    func anchorSignature(threadId: UUID?) -> String?

    /// Records the anchor signature. A nil value forgets it, which makes the next turn start cold.
    func setAnchorSignature(_ signature: String?, threadId: UUID?)

    /// Fingerprint of the prefix the last request of this thread carried, or nil if unknown.
    /// See `SentPrefix`.
    func sentPrefix(threadId: UUID?) -> SentPrefix?

    /// Records the prefix fingerprint. A nil value forgets it, which forces the next turn to
    /// assume the provider will write.
    func setSentPrefix(_ prefix: SentPrefix?, threadId: UUID?)
}

// MARK: - InMemoryContextWindowStateStore

/// Keeps the state for the lifetime of the process only. Used by tests and as the base for
/// callers that do not want persistence.
public final class InMemoryContextWindowStateStore: ContextWindowStateStore, @unchecked Sendable {

    private let lock = NSLock()
    private var times: [UUID: Date] = [:]
    private var anchors: [UUID: String] = [:]
    private var prefixes: [UUID: SentPrefix] = [:]

    public init() {}

    public func lastRequestAt(threadId: UUID?) -> Date? {
        guard let key = threadId else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return times[key]
    }

    public func setLastRequestAt(_ date: Date?, threadId: UUID?) {
        guard let key = threadId else { return }
        lock.lock()
        defer { lock.unlock() }
        times[key] = date
    }

    public func anchorSignature(threadId: UUID?) -> String? {
        guard let key = threadId else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return anchors[key]
    }

    public func setAnchorSignature(_ signature: String?, threadId: UUID?) {
        guard let key = threadId else { return }
        lock.lock()
        defer { lock.unlock() }
        anchors[key] = signature
    }

    public func sentPrefix(threadId: UUID?) -> SentPrefix? {
        guard let key = threadId else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return prefixes[key]
    }

    public func setSentPrefix(_ prefix: SentPrefix?, threadId: UUID?) {
        guard let key = threadId else { return }
        lock.lock()
        defer { lock.unlock() }
        prefixes[key] = prefix
    }
}

// MARK: - UserDefaultsContextWindowStateStore

/// Persists the state across launches in UserDefaults.
///
/// WHY NOT THE SQLITE STORE: both facts are worthless within a couple of hours and a wrong guess
/// costs one cache write, so they do not deserve a table, a migration, or a write per request.
/// UserDefaults is synchronous, thread-safe and costs microseconds.
///
/// One dictionary per fact, not one key per thread: entries are pruned on write, which needs the
/// whole set anyway, and this keeps deleted threads' leftovers bounded.
public final class UserDefaultsContextWindowStateStore: ContextWindowStateStore, @unchecked Sendable {

    /// Entries older than this are dropped on write. Well past any useful TTL, and short enough
    /// that deleted threads do not accumulate.
    static let retention: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults
    private let timeKey: String
    private let anchorKey: String
    private let prefixKey: String

    public init(
        defaults: UserDefaults = .standard,
        timeKey: String = "chappie.cacheWarmth.lastRequestAt",
        anchorKey: String = "chappie.contextWindow.anchorSignature",
        prefixKey: String = "chappie.contextWindow.sentPrefix"
    ) {
        self.defaults = defaults
        self.timeKey = timeKey
        self.anchorKey = anchorKey
        self.prefixKey = prefixKey
    }

    // MARK: Request time

    public func lastRequestAt(threadId: UUID?) -> Date? {
        guard let id = threadId?.uuidString else { return nil }
        guard let raw = defaults.dictionary(forKey: timeKey)?[id] as? Double else { return nil }
        return Date(timeIntervalSince1970: raw)
    }

    public func setLastRequestAt(_ date: Date?, threadId: UUID?) {
        guard let id = threadId?.uuidString else { return }
        var stored = defaults.dictionary(forKey: timeKey) ?? [:]

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

        defaults.set(stored, forKey: timeKey)
    }

    // MARK: Window anchor

    public func anchorSignature(threadId: UUID?) -> String? {
        guard let id = threadId?.uuidString else { return nil }
        return defaults.dictionary(forKey: anchorKey)?[id] as? String
    }

    public func setAnchorSignature(_ signature: String?, threadId: UUID?) {
        guard let id = threadId?.uuidString else { return }
        var stored = defaults.dictionary(forKey: anchorKey) ?? [:]

        if let signature {
            stored[id] = signature
        } else {
            stored.removeValue(forKey: id)
        }

        defaults.set(stored, forKey: anchorKey)
    }

    // MARK: Sent prefix

    public func sentPrefix(threadId: UUID?) -> SentPrefix? {
        guard let id = threadId?.uuidString else { return nil }
        guard let raw = defaults.dictionary(forKey: prefixKey)?[id] as? String else { return nil }
        // An unreadable entry is "nothing known", never a wrong answer: the turn then behaves as
        // if no prefix had been sent, which costs one honest cut.
        return SentPrefix(rawValue: raw)
    }

    public func setSentPrefix(_ prefix: SentPrefix?, threadId: UUID?) {
        guard let id = threadId?.uuidString else { return }
        var stored = defaults.dictionary(forKey: prefixKey) ?? [:]

        if let prefix {
            stored[id] = prefix.rawValue
        } else {
            stored.removeValue(forKey: id)
        }

        defaults.set(stored, forKey: prefixKey)
    }
}
