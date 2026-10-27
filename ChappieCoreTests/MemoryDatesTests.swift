// MemoryDatesTests.swift
// ChappieCoreTests
//
// Memory entries show their creation/update day in the system prompt, so the model can tell a
// stale "in progress" note from a fresh one.

import Testing
import Foundation
@testable import ChappieCore

@Suite("Memory entry dates")
struct MemoryDatesTests {

    private let utc = TimeZone(identifier: "UTC")!

    private func entry(created: Date, updated: Date) -> MemoryEntry {
        var e = MemoryEntry(key: "k", type: "fact", jsonString: "\"v\"")
        e.createdAt = created
        e.updatedAt = updated
        return e
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    @Test("day() is locale-independent and zero padded")
    func dayFormat() {
        #expect(MessageTimestamp.day(date("2026-03-05T10:00:00Z"), timeZone: utc) == "2026-03-05")
    }

    @Test("day() uses the given time zone")
    func dayTimeZone() {
        let moscow = TimeZone(identifier: "Europe/Moscow")!
        // 22:30 UTC is already the next day in Moscow (+03:00).
        #expect(MessageTimestamp.day(date("2026-10-26T22:30:00Z"), timeZone: moscow) == "2026-10-27")
    }

    @Test("Untouched entry shows only the creation day")
    func createdOnly() async {
        let manager = MemoryManager(workspaceURL: URL(fileURLWithPath: "/tmp"))
        let d = date("2026-10-20T09:00:00Z")
        let block = await manager.formatEntriesForPrompt([entry(created: d, updated: d)], title: "T", timeZone: utc)
        #expect(block == "## T\n- [fact] k (created 2026-10-20): \"v\"")
    }

    @Test("Updated entry shows both days")
    func createdAndUpdated() async {
        let manager = MemoryManager(workspaceURL: URL(fileURLWithPath: "/tmp"))
        let block = await manager.formatEntriesForPrompt(
            [entry(created: date("2026-10-20T09:00:00Z"), updated: date("2026-10-27T09:00:00Z"))],
            title: "T",
            timeZone: utc
        )
        #expect(block == "## T\n- [fact] k (created 2026-10-20, updated 2026-10-27): \"v\"")
    }

    @Test("Same entry always yields the same line (prompt cache stays valid)")
    func stable() async {
        let manager = MemoryManager(workspaceURL: URL(fileURLWithPath: "/tmp"))
        let e = entry(created: date("2026-10-20T09:00:00Z"), updated: date("2026-10-21T09:00:00Z"))
        let a = await manager.formatEntriesForPrompt([e], title: "T", timeZone: utc)
        let b = await manager.formatEntriesForPrompt([e], title: "T", timeZone: utc)
        #expect(a == b)
    }

    @Test("The real prompt path (SystemPromptBuilder) carries the dates too")
    func builderPathHasDates() {
        let e = MemoryEntry(key: "k", type: "fact", jsonString: "{\"value\": \"v\"}")
        let prompt = SystemPromptBuilder(personaBlock: "P").build(
            context: PromptContext(globalMemory: [e])
        )
        let label = MessageTimestamp.entryDates(created: e.createdAt, updated: e.updatedAt)
        #expect(prompt.contains("- [fact] k \(label): v"))
        #expect(label.hasPrefix("(created 20"))
    }

    @Test("Saving again keeps createdAt and bumps updatedAt")
    func saveKeepsCreated() async throws {
        let store = MemoryStore(dataStore: try SQLiteStorage(inMemory: true))
        try await store.saveEntry(key: "k", type: "fact", jsonString: "\"a\"", scope: "g")
        let first = try await store.readAllEntries(scope: "g")[0]
        try await Task.sleep(nanoseconds: 20_000_000)
        try await store.saveEntry(key: "k", type: "fact", jsonString: "\"b\"", scope: "g")
        let second = try await store.readAllEntries(scope: "g")[0]
        #expect(second.createdAt == first.createdAt)
        #expect(second.updatedAt > first.updatedAt)
    }
}
