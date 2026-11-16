// MemoryScopeTests.swift
// ChappieCoreTests
//
// Tests for MemoryScope storage strings and MemoryEntryOrdering display order.
//
// WHY THESE MATTER:
// The storage string is the only contract with data already on disk — a wrong spelling means
// the editor shows an empty list while the agent keeps reading entries from a different scope.
// The ordering is what the user scans to find a record, so it has to be identical on every
// opening, including for entries that share type and key.

import Testing
import Foundation
@testable import ChappieCore

@Suite("MemoryScope Tests")
struct MemoryScopeTests {

    @Test("Global scope stores under the literal 'global'")
    func globalRawValue() {
        #expect(MemoryScope.global.rawValue == "global")
    }

    @Test("Thread scope stores under the thread UUID")
    func threadRawValue() {
        let id = UUID()
        #expect(MemoryScope.thread(id).rawValue == id.uuidString)
    }

    @Test("Project scope stores under the project UUID")
    func projectRawValue() {
        let id = UUID()
        #expect(MemoryScope.project(id).rawValue == id.uuidString)
    }

    @Test("Thread and project scopes with the same UUID collide by design")
    func sameUuidSameStorage() {
        // Documents the hazard the enum exists for: the storage strings are identical,
        // so callers must never confuse the two levels. Here they are compared explicitly.
        let id = UUID()
        #expect(MemoryScope.thread(id).rawValue == MemoryScope.project(id).rawValue)
        #expect(MemoryScope.thread(id) != MemoryScope.project(id))
    }

    @Test("Scopes with different UUIDs are different")
    func differentUuids() {
        #expect(MemoryScope.thread(UUID()) != MemoryScope.thread(UUID()))
    }
}

@Suite("MemoryEntryOrdering Tests")
struct MemoryEntryOrderingTests {

    private func entry(key: String, type: String, id: UUID = UUID()) -> MemoryEntry {
        MemoryEntry(id: id, key: key, type: type, jsonString: "\"v\"")
    }

    @Test("Entries are ordered by type first")
    func typeIsOuterOrder() {
        let entries = [
            entry(key: "a", type: "rule"),
            entry(key: "z", type: "backlog"),
            entry(key: "m", type: "fact")
        ]

        let sorted = MemoryEntryOrdering.sorted(entries).map(\.type)

        #expect(sorted == ["backlog", "fact", "rule"])
    }

    @Test("Entries of one type are ordered by key")
    func keyIsInnerOrder() {
        let entries = [
            entry(key: "zeta", type: "rule"),
            entry(key: "alpha", type: "rule"),
            entry(key: "middle", type: "rule")
        ]

        let sorted = MemoryEntryOrdering.sorted(entries).map(\.key)

        #expect(sorted == ["alpha", "middle", "zeta"])
    }

    @Test("Same type and key falls back to id, not to input order")
    func idIsFinalTieBreaker() {
        let lowId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let highId = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000002")!

        // Deliberately given in the opposite order to the expected result.
        let sorted = MemoryEntryOrdering.sorted([
            entry(key: "dup", type: "fact", id: highId),
            entry(key: "dup", type: "fact", id: lowId)
        ]).map(\.id)

        #expect(sorted == [lowId, highId])
    }

    @Test("Ordering is stable across repeated calls")
    func orderingIsRepeatable() {
        let entries = [
            entry(key: "b", type: "rule"),
            entry(key: "a", type: "rule"),
            entry(key: "c", type: "backlog")
        ]

        let first = MemoryEntryOrdering.sorted(entries).map(\.key)
        let second = MemoryEntryOrdering.sorted(entries).map(\.key)

        #expect(first == second)
    }

    @Test("Empty input stays empty")
    func emptyInput() {
        #expect(MemoryEntryOrdering.sorted([]).isEmpty)
    }
}
