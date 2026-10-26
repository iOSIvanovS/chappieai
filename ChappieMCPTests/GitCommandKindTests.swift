// GitCommandKindTests.swift
//
// The git timeout table encodes a safety decision: reads are short, anything that may run hooks
// or talk to a remote gets minutes, and only mutating kinds are shielded from "Stop".

import Testing
import Foundation
@testable import ChappieMCPCore

struct GitCommandKindTests {

    @Test func mutatingKindsAreNotCancellable() {
        #expect(GitCommandKind.read.isMutating == false)
        #expect(GitCommandKind.local.isMutating)
        #expect(GitCommandKind.hooked.isMutating)
        #expect(GitCommandKind.push.isMutating)
    }

    @Test func timeoutsGrowWithRisk() {
        let read = GitCommandKind.read.timeout
        let local = GitCommandKind.local.timeout
        let hooked = GitCommandKind.hooked.timeout
        let push = GitCommandKind.push.timeout

        #expect(read > 0)
        #expect(local > read)
        #expect(hooked > local)
        // Hooks and push share the long ceiling; push is additionally guarded by stall detection.
        #expect(push == hooked)
    }

    @Test func timeoutsKeepTheirRatios() {
        // Independent of CHAPPIE_MCP_TIMEOUT_SCALE (a live-check helper): only ratios are fixed.
        let read = GitCommandKind.read.timeout
        #expect(abs(GitCommandKind.local.timeout / read - 2) < 0.0001)
        #expect(abs(GitCommandKind.hooked.timeout / read - 10) < 0.0001)
    }
}
