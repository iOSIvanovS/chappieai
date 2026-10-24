import Testing
import Foundation
@testable import ChappieCore

@Suite("ToolArguments: lenient parsing of model-supplied arguments")
struct ToolArgumentsTests {

    private func parsed(_ json: String) -> [String: String]? {
        if case .success(let map) = ToolArguments.parse(json) { return map }
        return nil
    }

    @Test("Plain string maps are unchanged")
    func strings() {
        #expect(parsed(#"{"project":"A","path":"x.swift"}"#) == ["project": "A", "path": "x.swift"])
    }

    @Test("Numbers and booleans are stringified and the project survives")
    func scalars() {
        let map = parsed(#"{"project":"A","timeout":30,"ratio":0.5,"recursive":true,"quiet":false}"#)
        #expect(map == ["project": "A", "timeout": "30", "ratio": "0.5", "recursive": "true", "quiet": "false"])
    }

    @Test("A number 1 is not mistaken for a boolean, and true is not mistaken for 1")
    func numberVersusBool() {
        #expect(parsed(#"{"a":1,"b":true,"c":0,"d":false}"#) == ["a": "1", "b": "true", "c": "0", "d": "false"])
    }

    @Test("null drops the key")
    func nulls() {
        #expect(parsed(#"{"project":"A","path":null}"#) == ["project": "A"])
    }

    @Test("Nested objects and arrays become compact JSON text with sorted keys")
    func nested() {
        let map = parsed(#"{"project":"A","translations":{"b":{"ru":"x"},"a":{"de":"y"}},"items":[1,2]}"#)
        #expect(map?["project"] == "A")
        #expect(map?["translations"] == #"{"a":{"de":"y"},"b":{"ru":"x"}}"#)
        #expect(map?["items"] == "[1,2]")
    }

    @Test("Unicode and escapes survive")
    func unicode() {
        #expect(parsed(#"{"q":"привет \"мир\"\n"}"#)?["q"] == "привет \"мир\"\n")
    }

    @Test("Empty input means no arguments", arguments: ["", "   ", "null", "{}", #""""#])
    func empty(raw: String) {
        #expect(parsed(raw) == [:])
    }

    @Test("Double-encoded objects are unwrapped once")
    func doubleEncoded() {
        #expect(parsed(#""{\"project\":\"A\",\"n\":3}""#) == ["project": "A", "n": "3"])
    }

    @Test("Broken JSON is an explicit error, not empty arguments")
    func broken() {
        #expect(ToolArguments.parse("{\"a\":") == .failure(.invalidJSON))
        #expect(ToolArguments.parse("not json") == .failure(.invalidJSON))
    }

    @Test("Non-objects are an explicit error", arguments: ["[1,2]", "42", "true", #""just text""#])
    func notAnObject(raw: String) {
        #expect(ToolArguments.parse(raw) == .failure(.notAnObject))
    }

    @Test("The explanation names the tool")
    func explanation() {
        #expect(ToolArguments.explanation(for: .invalidJSON, tool: "read_file").contains("read_file"))
        #expect(ToolArguments.explanation(for: .notAnObject, tool: "run_tests").contains("run_tests"))
    }
}
