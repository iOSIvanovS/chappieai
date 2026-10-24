// SaveQueueTests.swift
// ChappieCoreTests
//
// Regression tests for backlog_02a: writes are ordered, a failed write pauses the queue and
// waits for Retry / Skip instead of being swallowed.

import Testing
import Foundation
@testable import ChappieCore

private actor Recorder {
    private(set) var events: [String] = []
    private var attempts: [String: Int] = [:]

    func add(_ event: String) { events.append(event) }
    func attempt(_ name: String) -> Int {
        attempts[name, default: 0] += 1
        return attempts[name]!
    }
}

private struct DiskFull: LocalizedError {
    var errorDescription: String? { "No space left on device" }
}

@MainActor
@Suite("SaveQueue")
struct SaveQueueTests {

    @Test("Writes run strictly in submission order even when earlier ones are slower")
    func preservesOrder() async {
        let queue = SaveQueue()
        let rec = Recorder()
        queue.enqueue(label: "1") { try await Task.sleep(nanoseconds: 60_000_000); await rec.add("1") }
        queue.enqueue(label: "2") { try await Task.sleep(nanoseconds: 20_000_000); await rec.add("2") }
        queue.enqueue(label: "3") { await rec.add("3") }

        await queue.waitUntilSettled()

        #expect(await rec.events == ["1", "2", "3"])
    }

    @Test("A failure pauses the queue: later writes do not overtake it, the UI is told why")
    func failureBlocksQueue() async {
        let queue = SaveQueue()
        let rec = Recorder()
        var reported: [SaveFailure?] = []
        queue.onFailureChanged = { reported.append($0) }

        queue.enqueue(label: "first") { await rec.add("first"); throw DiskFull() }
        queue.enqueue(label: "second") { await rec.add("second") }
        await queue.waitUntilSettled()

        #expect(queue.isBlocked)
        #expect(await rec.events == ["first"])
        #expect(reported.count == 1)
        #expect(reported.first??.reason == "No space left on device")
    }

    @Test("Retry re-runs the failed write first, then the rest")
    func retryRunsFailedFirst() async {
        let queue = SaveQueue()
        let rec = Recorder()
        queue.enqueue(label: "first") {
            await rec.add("first")
            if await rec.attempt("first") == 1 { throw DiskFull() }
        }
        queue.enqueue(label: "second") { await rec.add("second") }
        await queue.waitUntilSettled()
        #expect(queue.isBlocked)

        queue.retry()
        await queue.waitUntilSettled()

        #expect(!queue.isBlocked)
        #expect(await rec.events == ["first", "first", "second"])
    }

    @Test("Skip drops the failed write and continues with the rest")
    func skipContinues() async {
        let queue = SaveQueue()
        let rec = Recorder()
        var last: SaveFailure? = SaveFailure(label: "x", reason: "x")
        queue.onFailureChanged = { last = $0 }

        queue.enqueue(label: "first") { await rec.add("first"); throw DiskFull() }
        queue.enqueue(label: "second") { await rec.add("second") }
        await queue.waitUntilSettled()

        queue.skip()
        await queue.waitUntilSettled()

        #expect(!queue.isBlocked)
        #expect(last == nil) // the UI was told the failure is resolved
        #expect(await rec.events == ["first", "second"])
    }

    @Test("Retry that fails again blocks again")
    func repeatedFailure() async {
        let queue = SaveQueue()
        var reports = 0
        queue.onFailureChanged = { if $0 != nil { reports += 1 } }
        queue.enqueue(label: "bad") { throw DiskFull() }
        await queue.waitUntilSettled()

        queue.retry()
        await queue.waitUntilSettled()

        #expect(queue.isBlocked)
        #expect(reports == 2)
    }

    @Test("Pending snapshots with the same key collapse into the newest one")
    func coalescing() async {
        let queue = SaveQueue()
        let rec = Recorder()
        queue.enqueue(label: "v1", coalesceKey: "t") { await rec.add("v1") }
        queue.enqueue(label: "v2", coalesceKey: "t") { await rec.add("v2") }
        queue.enqueue(label: "other", coalesceKey: "u") { await rec.add("other") }
        queue.enqueue(label: "v3", coalesceKey: "t") { await rec.add("v3") }

        await queue.waitUntilSettled()

        #expect(await rec.events == ["other", "v3"])
    }

    @Test("submit returns after success")
    func submitWaitsForSuccess() async {
        let queue = SaveQueue()
        let rec = Recorder()
        await queue.submit(label: "s") { await rec.add("done") }
        #expect(await rec.events == ["done"])
    }

    @Test("submit returns once the user skips a failed write")
    func submitReturnsOnSkip() async {
        let queue = SaveQueue()
        queue.onFailureChanged = { [queue] failure in
            if failure != nil { Task { @MainActor in queue.skip() } }
        }
        await queue.submit(label: "s") { throw DiskFull() }
        #expect(!queue.isBlocked)
    }

    @Test("afterSuccess runs only when the write succeeded")
    func afterSuccessOnlyOnSuccess() async {
        let queue = SaveQueue()
        let rec = Recorder()
        queue.enqueue(label: "ok", afterSuccess: { await rec.add("ok-after") }) { }
        queue.enqueue(label: "bad", afterSuccess: { await rec.add("bad-after") }) { throw DiskFull() }
        await queue.waitUntilSettled()

        #expect(await rec.events == ["ok-after"])
    }
}
