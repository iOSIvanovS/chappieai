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

    // MARK: - Determinism of the displayed payload
    //
    // WHY these tests exist: the payload of a multi-key entry used to be `json.values.first`.
    // JSONSerialization turns a JSON object into a Dictionary, and Swift seeds Dictionary order
    // PER PROCESS — so the same stored entry produced different prompt text after every relaunch.
    // The system prompt changed, the provider cache never matched, and the whole prefix was
    // rewritten on each restart. Measured: `read 0 | wrote 98045` after relaunch vs
    // `read 94292 (99%)` inside one process.

    /// Multi-key entries, each with a known value per key.
    private static let multiKeyEntries: [(String, [String: String])] = [
        ("{\"a\":\"VA\",\"b\":\"VB\"}", ["a": "VA", "b": "VB"]),
        ("{\"z\":\"VZ\",\"m\":\"VM\"}", ["m": "VM", "z": "VZ"]),
        ("{\"incident\":\"I\",\"pattern\":\"P\",\"corrective_action\":\"C\"}",
         ["incident": "I", "pattern": "P", "corrective_action": "C"]),
        ("{\"alpha\":\"X1\",\"omega\":\"X3\",\"beta\":\"X2\"}",
         ["alpha": "X1", "omega": "X3", "beta": "X2"]),
    ]

    @Test("A multi-key entry shows the field of its smallest key — sorted, not dictionary order")
    func multiKeyIsDeterministic() {
        for (json, fields) in Self.multiKeyEntries {
            let entry = MemoryEntry(key: "k", type: "fact", jsonString: json)
            let smallestKey = fields.keys.sorted().first!
            #expect(entry.promptDisplayValue == fields[smallestKey]!,
                    "json \(json) should show the value of '\(smallestKey)'")
        }
    }

    @Test("The 'value' field wins over any other field")
    func valueFieldWins() {
        let entry = MemoryEntry(key: "k", type: "fact",
                                jsonString: "{\"value\":\"real\",\"aaa\":\"decoy\"}")
        #expect(entry.promptDisplayValue == "real")
    }

    @Test("Field order in the stored JSON text makes no difference")
    func sourceOrderIrrelevant() {
        let a = MemoryEntry(key: "k", type: "fact", jsonString: "{\"a\":\"1\",\"b\":\"2\"}")
        let b = MemoryEntry(key: "k", type: "fact", jsonString: "{\"b\":\"2\",\"a\":\"1\"}")
        #expect(a.promptDisplayValue == b.promptDisplayValue)
    }

    @Test("Non-object payloads fall back to the raw string")
    func rawFallback() {
        #expect(MemoryEntry(key: "k", type: "fact", jsonString: "\"v\"").promptDisplayValue == "\"v\"")
        #expect(MemoryEntry(key: "k", type: "fact", jsonString: "42").promptDisplayValue == "42")
        #expect(MemoryEntry(key: "k", type: "fact", jsonString: "{}").promptDisplayValue == "{}")
    }

    @Test("The system prompt is identical for the same entries — the cacheable prefix holds")
    func promptIsStable() {
        let entries = Self.multiKeyEntries.map {
            MemoryEntry(key: "k\($0.0.count)", type: "fact", jsonString: $0.0)
        }
        let builder = SystemPromptBuilder(personaBlock: "P")
        let ctx = PromptContext(globalMemory: entries)
        #expect(builder.build(context: ctx) == builder.build(context: ctx))
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
