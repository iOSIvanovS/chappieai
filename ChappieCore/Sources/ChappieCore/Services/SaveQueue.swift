// SaveQueue.swift
// ChappieCore
//
// Serial queue for user-data writes. Replaces fire-and-forget `Task { try? await save }`.
//
// WHY:
// 1. Order. Independent Tasks can finish out of order, so an older snapshot of a thread could be
//    written after a newer one and silently revert it. One queue = strict order.
// 2. Errors. A failed write pauses the queue and is handed to the UI (retry / skip) instead of
//    being thrown away. Later writes wait, so nothing newer overtakes the failed one.
//
// WHY @MainActor: callers are on the main actor, and `enqueue` must register synchronously to keep
// the caller's order. Only registration and bookkeeping run here; the write itself is awaited.
//
// SKIP IS SAFE for message saves: every save writes the whole loaded window, so a skipped
// snapshot is covered by the next successful one. The data stays in memory until then.

import Foundation

// MARK: - SaveFailure

/// A write that failed and now waits for the user's decision.
public struct SaveFailure: Sendable, Identifiable, Equatable {
    public let id: UUID
    /// Short English name of what failed (for logs).
    public let label: String
    /// Localized system description of the underlying error.
    public let reason: String

    public init(id: UUID = UUID(), label: String, reason: String) {
        self.id = id
        self.label = label
        self.reason = reason
    }
}

// MARK: - SaveQueue

@MainActor
public final class SaveQueue {

    public typealias Operation = @Sendable () async throws -> Void
    public typealias Completion = @MainActor () async -> Void

    private struct Item {
        let label: String
        let coalesceKey: String?
        let run: Operation
        let afterSuccess: Completion?
        let waiter: CheckedContinuation<Void, Never>?
    }

    private var pending: [Item] = []
    private var blocked: Item?
    private var isDraining = false
    private var settleWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called with a failure when the queue pauses, and with nil once the user resolved it.
    public var onFailureChanged: ((SaveFailure?) -> Void)?

    public init() {}

    // MARK: Submit

    /// Fire and forget. Items with the same `coalesceKey` that have not started yet are replaced
    /// by the newest one — only use it for full-snapshot writes where the latest state wins.
    /// `afterSuccess` runs on the main actor after the write succeeded.
    public func enqueue(
        label: String,
        coalesceKey: String? = nil,
        afterSuccess: Completion? = nil,
        _ run: @escaping Operation
    ) {
        if let key = coalesceKey {
            // A replaced item never ran, so its waiter (if any) must still be released.
            for dropped in pending where dropped.coalesceKey == key { dropped.waiter?.resume() }
            pending.removeAll { $0.coalesceKey == key }
        }
        pending.append(Item(label: label, coalesceKey: coalesceKey, run: run, afterSuccess: afterSuccess, waiter: nil))
        startDrainIfNeeded()
    }

    /// Returns after the write succeeded, or after the user chose to skip it after a failure.
    public func submit(label: String, _ run: @escaping Operation) async {
        await withCheckedContinuation { continuation in
            pending.append(Item(label: label, coalesceKey: nil, run: run, afterSuccess: nil, waiter: continuation))
            startDrainIfNeeded()
        }
    }

    // MARK: User decision

    /// Runs the failed write again before anything queued after it.
    public func retry() {
        guard let item = blocked else { return }
        blocked = nil
        pending.insert(item, at: 0)
        onFailureChanged?(nil)
        startDrainIfNeeded()
    }

    /// Drops the failed write and continues with the rest.
    public func skip() {
        guard let item = blocked else { return }
        blocked = nil
        item.waiter?.resume()
        onFailureChanged?(nil)
        startDrainIfNeeded()
    }

    // MARK: Observation

    /// True while a failed write waits for the user.
    public var isBlocked: Bool { blocked != nil }

    /// Suspends until the queue is empty or paused on a failure. Used by tests and by app quit.
    public func waitUntilSettled() async {
        guard isDraining else { return }
        await withCheckedContinuation { settleWaiters.append($0) }
    }

    // MARK: Draining

    private func startDrainIfNeeded() {
        guard !isDraining, blocked == nil, !pending.isEmpty else { return }
        isDraining = true
        Task { await drain() }
    }

    private func drain() async {
        while blocked == nil, !pending.isEmpty {
            let item = pending.removeFirst()
            do {
                try await item.run()
                await item.afterSuccess?()
                item.waiter?.resume()
            } catch {
                print("[SaveQueue] ❌ '\(item.label)' failed: \(error)")
                blocked = item
                onFailureChanged?(SaveFailure(label: item.label, reason: error.localizedDescription))
            }
        }
        isDraining = false
        let waiters = settleWaiters
        settleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
