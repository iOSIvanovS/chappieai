// TerminalSwitchMigrationTests.swift
// ChappieCoreTests
//
// The three-level terminal setting (none / confirm / auto) became an on/off switch. Stored threads
// must keep decoding, must land on the safe side, and must not lose their other settings or projects.

import Testing
import Foundation
@testable import ChappieCore

@Suite("Terminal switch migration")
struct TerminalSwitchMigrationTests {

    private func decode(_ json: String) throws -> ThreadSettings {
        try JSONDecoder().decode(ThreadSettings.self, from: Data(json.utf8))
    }

    @Test("Legacy value maps to the switch: only auto turns it on",
          arguments: [("auto", true), ("confirm", false), ("none", false), ("garbage", false), ("", false)])
    func legacyStrings(raw: String, expected: Bool) throws {
        let s = try decode(#"{"maxMessagesInContext":70,"activeModelName":"m","terminalAccess":"\#(raw)"}"#)
        #expect(s.terminalEnabled == expected)
        #expect(s.maxMessagesInContext == 70)
        #expect(s.activeModelName == "m")
    }

    @Test("Legacy value of a wrong type or null leaves the switch off and the rest intact")
    func legacyWrongTypes() throws {
        for value in ["42", "true", "null", "[1,2]", #"{"a":1}"#] {
            let s = try decode(#"{"maxMessagesInContext":50,"terminalAccess":\#(value)}"#)
            #expect(!s.terminalEnabled, "value \(value)")
            #expect(s.maxMessagesInContext == 50, "value \(value)")
        }
    }

    @Test("Missing key means off")
    func missingKey() throws {
        #expect(try !decode("{}").terminalEnabled)
    }

    @Test("New key wins over the legacy one")
    func newKeyWins() throws {
        #expect(try decode(#"{"terminalEnabled":true,"terminalAccess":"none"}"#).terminalEnabled)
        #expect(try !decode(#"{"terminalEnabled":false,"terminalAccess":"auto"}"#).terminalEnabled)
    }

    @Test("A broken new key does not fail the whole record")
    func brokenNewKey() throws {
        let s = try decode(#"{"terminalEnabled":"yes","maxMessagesInContext":90}"#)
        #expect(!s.terminalEnabled)
        #expect(s.maxMessagesInContext == 90)
    }

    @Test("Round trip writes only the new key")
    func roundTrip() throws {
        var s = ThreadSettings()
        s.terminalEnabled = true
        let data = try JSONEncoder().encode(s)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("terminalAccess"))
        #expect(text.contains("terminalEnabled"))
        #expect(try JSONDecoder().decode(ThreadSettings.self, from: data) == s)
    }

    @Test("Project settings with any legacy terminal value decode and the project list survives",
          arguments: ["auto", "confirm", "none", "garbage"])
    func projectSettingsLegacy(raw: String) throws {
        let entryJSON = """
        [{"id":"\(UUID().uuidString)","display_name":"P","absolute_path":"/tmp/p",
          "settings":{"agentRole":"executor","terminalAccess":"\(raw)","buildEnabled":false},
          "created_at":0}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let entries = try decoder.decode([ThreadProjectEntry].self, from: Data(entryJSON.utf8))
        #expect(entries.count == 1)
        #expect(entries[0].settings.agentRole == .executor)
        #expect(entries[0].settings.buildEnabled == false)
    }
}
