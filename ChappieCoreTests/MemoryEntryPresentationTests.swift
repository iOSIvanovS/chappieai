// MemoryEntryPresentationTests.swift
// ChappieCoreTests
//
// The editor offers the full JSON only when the displayed text hides fields.

import Testing
import Foundation
@testable import ChappieCore

@Suite("MemoryEntryPresentation Tests")
struct MemoryEntryPresentationTests {

    private func entry(_ json: String) -> MemoryEntry {
        MemoryEntry(key: "k", type: "fact", jsonString: json)
    }

    @Test("Plain string payload hides nothing")
    func plainString() {
        #expect(MemoryEntryPresentation.hiddenFieldsJSON(for: entry("just text")) == nil)
        #expect(MemoryEntryPresentation.hiddenFieldsJSON(for: entry("\"quoted\"")) == nil)
    }

    @Test("Single-key object hides nothing")
    func singleKey() {
        #expect(MemoryEntryPresentation.hiddenFieldsJSON(for: entry("{\"value\":\"x\"}")) == nil)
        #expect(MemoryEntryPresentation.hiddenFieldsJSON(for: entry("{\"incident\":\"x\"}")) == nil)
    }

    @Test("Empty object and array hide nothing")
    func emptyContainers() {
        #expect(MemoryEntryPresentation.hiddenFieldsJSON(for: entry("{}")) == nil)
        #expect(MemoryEntryPresentation.hiddenFieldsJSON(for: entry("[1,2]")) == nil)
    }

    @Test("Multi-key object exposes every field")
    func multiKey() throws {
        let json = "{\"pattern\":\"p\",\"incident\":\"i\",\"corrective_action\":\"c\"}"

        let shown = try #require(MemoryEntryPresentation.hiddenFieldsJSON(for: entry(json)))

        #expect(shown.contains("\"pattern\""))
        #expect(shown.contains("\"incident\""))
        #expect(shown.contains("\"corrective_action\""))
    }

    @Test("Output is identical on every call")
    func deterministic() throws {
        let json = "{\"b\":\"2\",\"a\":\"1\",\"c\":\"3\"}"

        let first = try #require(MemoryEntryPresentation.hiddenFieldsJSON(for: entry(json)))
        let second = try #require(MemoryEntryPresentation.hiddenFieldsJSON(for: entry(json)))

        #expect(first == second)

        let positionA = try #require(first.range(of: "\"a\"")).lowerBound
        let positionB = try #require(first.range(of: "\"b\"")).lowerBound
        #expect(positionA < positionB)
    }

    @Test("Slashes and non-ASCII text stay readable")
    func readableText() throws {
        let json = "{\"url\":\"https://x.y/z\",\"note\":\"запись\"}"

        let shown = try #require(MemoryEntryPresentation.hiddenFieldsJSON(for: entry(json)))

        #expect(shown.contains("https://x.y/z"))
        #expect(shown.contains("запись"))
    }
}
