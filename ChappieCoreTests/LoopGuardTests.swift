// LoopGuardTests.swift
// ChappieCoreTests
//
// The guard blocks the 3rd identical call only while every result stayed identical.

import Testing
@testable import ChappieCore

@Suite("LoopGuard")
struct LoopGuardTests {

    private let sig = "git_status|{}"

    @Test("First and second identical calls run")
    func firstTwoRun() {
        var guardian = LoopGuard()
        #expect(!guardian.shouldBlock(signature: sig))
        guardian.record(signature: sig, result: "clean")
        #expect(!guardian.shouldBlock(signature: sig))
        guardian.record(signature: sig, result: "clean")
    }

    @Test("Third identical call with an identical result is blocked")
    func thirdBlocked() {
        var guardian = LoopGuard()
        guardian.record(signature: sig, result: "clean")
        guardian.record(signature: sig, result: "clean")
        #expect(guardian.shouldBlock(signature: sig))
    }

    @Test("A changed result is progress: the count restarts")
    func changedResultResets() {
        var guardian = LoopGuard()
        guardian.record(signature: sig, result: "building")
        guardian.record(signature: sig, result: "building")
        // Third call would be blocked, but suppose it had run and returned something new.
        guardian.record(signature: sig, result: "done")
        #expect(!guardian.shouldBlock(signature: sig))
        guardian.record(signature: sig, result: "done")
        #expect(guardian.shouldBlock(signature: sig))
    }

    @Test("A different call in between resets the streak")
    func differentCallResets() {
        var guardian = LoopGuard()
        guardian.record(signature: sig, result: "clean")
        guardian.record(signature: sig, result: "clean")
        guardian.record(signature: "git_log|{}", result: "log")
        #expect(!guardian.shouldBlock(signature: sig))
    }

    @Test("A blocked call that is not recorded keeps the guard locked, not extended")
    func blockedStaysBlocked() {
        var guardian = LoopGuard()
        guardian.record(signature: sig, result: "clean")
        guardian.record(signature: sig, result: "clean")
        #expect(guardian.shouldBlock(signature: sig))
        #expect(guardian.shouldBlock(signature: sig))
        // Changing the arguments always gets through.
        #expect(!guardian.shouldBlock(signature: "git_status|{\"project\":\"A\"}"))
    }

    @Test("The message explains why and what to do")
    func messageExplains() {
        let text = LoopGuard.blockedMessage(toolName: "read_file")
        #expect(text.contains("read_file"))
        #expect(text.contains("NOT run"))
        #expect(text.contains("same result"))
        #expect(text.contains("What to do"))
    }
}
