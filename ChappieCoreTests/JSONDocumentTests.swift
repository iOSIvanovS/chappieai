// JSONDocumentTests.swift
// ChappieCoreTests
//
// Parser with byte positions and style detection (pass J1 of the json_* toolset).
// The fixtures are small copies of the shapes that matter: an Xcode string catalog,
// package.json, tsconfig with comments, a minified file, tabs, CRLF and a BOM.

import Testing
import Foundation
@testable import ChappieCore

private enum Fixtures {
    /// Xcode string catalog layout: " : " separator, "\/" escape, empty object split over lines, no final newline.
    static let xcstrings = """
    {
      "sourceLanguage" : "en",
      "strings" : {
        "" : {

        },
        "%lld files" : {
          "localizations" : {
            "en" : {
              "variations" : {
                "plural" : {
                  "one" : {
                    "stringUnit" : {
                      "state" : "translated",
                      "value" : "%lld file"
                    }
                  }
                }
              }
            }
          }
        },
        "path" : {
          "localizations" : {
            "ru" : {
              "stringUnit" : {
                "state" : "translated",
                "value" : "a\\/b \\u0416"
              }
            }
          }
        }
      },
      "version" : "1.0"
    }
    """

    static let packageJSON = "{\n    \"name\": \"demo\",\n    \"version\": \"1.0.0\",\n    \"scripts\": {\n        \"test\": \"jest\"\n    },\n    \"files\": [\"a\", \"b\"]\n}\n"

    static let tsconfig = """
    {
      // compiler options
      "compilerOptions": {
        "target": "es2020", /* inline */
        "strict": true,
      },
      "include": ["src"],
    }
    """

    static let minified = #"{"a":1,"b":[true,false,null],"c":{"d":"e"}}"#

    static let tabs = "{\n\t\"a\": 1,\n\t\"b\": {\n\t\t\"c\": 2\n\t}\n}\n"

    static let crlf = "{\r\n  \"a\": 1,\r\n  \"b\": 2\r\n}\r\n"
}

@Suite("JSONParser — structure and positions")
struct JSONParserTests {

    @Test("Every node range points at exactly the text of its value")
    func rangesAreExact() throws {
        let doc = try JSONDocument.parse(Fixtures.packageJSON)
        let name = try #require(doc.member("name", of: doc.root))
        #expect(doc.rawText(of: name) == "\"demo\"")
        #expect(doc.stringValue(of: name) == "demo")
        let scripts = try #require(doc.member("scripts", of: doc.root))
        #expect(doc.rawText(of: scripts) == "{\n        \"test\": \"jest\"\n    }")
        let files = try #require(doc.member("files", of: doc.root))
        #expect(doc.rawText(of: files) == "[\"a\", \"b\"]")
        #expect(doc.node(files).children.count == 2)
    }

    @Test("A key keeps its own byte range, separate from the value")
    func keyRange() throws {
        let doc = try JSONDocument.parse(#"{"alpha" : 12}"#)
        let member = try #require(doc.member("alpha", of: doc.root))
        let node = doc.node(member)
        #expect(String(decoding: doc.bytes[node.keyStart..<node.keyEnd], as: UTF8.self) == "\"alpha\"")
        #expect(String(decoding: doc.bytes[node.keyEnd..<node.start], as: UTF8.self) == " : ")
        #expect(doc.rawText(of: member) == "12")
    }

    @Test("Scalars of every kind get the right kind")
    func scalarKinds() throws {
        let doc = try JSONDocument.parse(#"{"s":"x","n":-1.5e+3,"t":true,"f":false,"z":null,"a":[],"o":{}}"#)
        let kinds = doc.node(doc.root).children.map { doc.node($0).kind }
        #expect(kinds == [.string, .number, .bool, .bool, .null, .array, .object])
    }

    @Test("Keys with dots, slashes and escapes are decoded")
    func decodedKeys() throws {
        let doc = try JSONDocument.parse(#"{"chat.send.title":1,"a\/b":2,"\u0416":3,"q\"":4}"#)
        let keys = doc.node(doc.root).children.compactMap { doc.node($0).key }
        #expect(keys == ["chat.send.title", "a/b", "Ж", "q\""])
    }

    @Test("Surrogate pairs become one character")
    func surrogates() throws {
        let doc = try JSONDocument.parse(#"{"k":"\ud83d\ude00"}"#)
        let value = try #require(doc.member("k", of: doc.root))
        #expect(doc.stringValue(of: value) == "😀")
    }

    @Test("Duplicate keys are reported and the first one wins")
    func duplicates() throws {
        let doc = try JSONDocument.parse(#"{"a":1,"a":2}"#)
        #expect(doc.facts.hasDuplicateKeys)
        let first = try #require(doc.member("a", of: doc.root))
        #expect(doc.rawText(of: first) == "1")
    }

    @Test("Parents precede children and depth grows by one")
    func orderAndDepth() throws {
        let doc = try JSONDocument.parse(Fixtures.xcstrings)
        for (index, node) in doc.nodes.enumerated() where index > 0 {
            #expect(node.parent < index)
            #expect(node.depth == doc.node(node.parent).depth + 1)
            #expect(node.start >= doc.node(node.parent).start && node.end <= doc.node(node.parent).end)
        }
    }

    @Test("Line numbers are 1-based and the trailing newline adds no line")
    func lines() throws {
        let doc = try JSONDocument.parse(Fixtures.packageJSON)
        #expect(doc.lineCount == 8)
        let scripts = try #require(doc.member("scripts", of: doc.root))
        #expect(doc.lineNumber(at: doc.node(scripts).memberStart) == 4)
        #expect(doc.lineNumber(at: 0) == 1)
    }

    @Test("Ancestry runs from the root down")
    func ancestry() throws {
        let doc = try JSONDocument.parse(#"{"a":{"b":[1,2]}}"#)
        let a = try #require(doc.member("a", of: doc.root))
        let b = try #require(doc.member("b", of: a))
        let second = try #require(doc.element(1, of: b))
        #expect(doc.ancestry(of: second) == [doc.root, a, b, second])
        #expect(doc.element(-1, of: b) == second)
        #expect(doc.element(5, of: b) == nil)
    }
}

@Suite("JSONParser — comments, errors and limits")
struct JSONParserEdgeTests {

    @Test("Comments and trailing commas are accepted and reported")
    func jsonc() throws {
        let doc = try JSONDocument.parse(Fixtures.tsconfig)
        #expect(doc.facts.hasComments)
        #expect(doc.facts.hasTrailingCommas)
        let options = try #require(doc.member("compilerOptions", of: doc.root))
        #expect(doc.node(options).children.count == 2)
    }

    @Test("A slash inside a string is not a comment")
    func slashInString() throws {
        let doc = try JSONDocument.parse(#"{"u":"http://x.y/*z*/"}"#)
        #expect(!doc.facts.hasComments)
    }

    @Test("A BOM is skipped and offsets stay absolute")
    func bom() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(#"{"a":1}"#.utf8))
        let doc = try JSONDocument.parse(data)
        #expect(doc.bomLength == 3)
        #expect(doc.node(doc.root).start == 3)
        let a = try #require(doc.member("a", of: doc.root))
        #expect(doc.rawText(of: a) == "1")
        #expect(JSONStyle.detect(doc).hasBOM)
    }

    @Test("Errors name the line and column", arguments: [
        ("{\"a\":1,}x", "Unexpected content"),
        ("{\"a\" 1}", "':' was expected"),
        ("{\"a\":}", "value was expected"),
        ("[1,2", "',' or ']'"),
        ("\"abc", "not closed"),
        ("{\"a\":tru}", "'true' was expected"),
        ("{\"a\":01}", "',' or '}'"),
        ("", "empty"),
        ("{\"a\":\"\\q\"}", "Unknown escape"),
        ("/* open", "not closed"),
    ])
    func errors(source: String, expectation: String) {
        do {
            _ = try JSONDocument.parse(source)
            Issue.record("Expected an error for: \(source)")
        } catch let error as JSONParseError {
            #expect(error.message.contains(expectation) || (error.errorDescription ?? "").contains(expectation),
                    "got: \(error.message)")
            #expect(error.line >= 1 && error.column >= 1)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("The error position is on the right line")
    func errorLine() {
        let source = "{\n  \"a\": 1,\n  \"b\": ?\n}"
        do {
            _ = try JSONDocument.parse(source)
            Issue.record("Expected an error")
        } catch let error as JSONParseError {
            #expect(error.line == 3)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Absurd nesting is refused instead of crashing")
    func deepNesting() {
        let source = String(repeating: "[", count: JSONParser.maxDepth + 10)
        #expect(throws: JSONParseError.self) { try JSONDocument.parse(source) }
    }

    @Test("Nesting at the limit parses on a small worker-thread stack")
    func deepNestingAtLimit() async throws {
        // The recursive parser overflowed a Swift Concurrency worker stack at ~190 levels (SIGBUS).
        let depth = JSONParser.maxDepth
        let source = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        let doc = try await Task.detached { try JSONDocument.parse(source) }.value
        #expect(doc.nodes.count == depth)
        #expect(doc.node(doc.nodes.count - 1).depth == depth - 1)
    }

    @Test("Deep objects keep keys, parents and ranges")
    func deepObjects() throws {
        let depth = 300
        var source = ""
        for level in 0..<depth { source += "{\"k\(level)\":" }
        source += "1" + String(repeating: "}", count: depth)
        let doc = try JSONDocument.parse(source)
        #expect(doc.nodes.count == depth + 1)
        let last = doc.nodes[depth]
        #expect(last.key == "k\(depth - 1)")
        #expect(doc.rawText(of: depth) == "1")
        #expect(doc.node(0).end == doc.bytes.count)
    }

    @Test("A large flat object parses and keeps its order")
    func largeObject() throws {
        var text = "{"
        for index in 0..<20_000 { text += (index > 0 ? "," : "") + "\"key\(index)\":\(index)" }
        text += "}"
        let doc = try JSONDocument.parse(text)
        #expect(doc.node(doc.root).children.count == 20_000)
        #expect(doc.node(doc.node(doc.root).children[19_999]).key == "key19999")
    }
}

@Suite("JSONStyle — detection")
struct JSONStyleTests {

    @Test("Xcode string catalog: the exact fingerprint")
    func xcstringsStyle() throws {
        let style = JSONStyle.detect(try JSONDocument.parse(Fixtures.xcstrings))
        #expect(style.indentUnit == "  ")
        #expect(style.keySeparator == " : ")
        #expect(style.lineEnding == "\n")
        #expect(!style.endsWithNewline)
        #expect(style.slashEscaping == .escaped)
        #expect(style.emptyObjectForm == "{\n\n}")
        #expect(!style.hasComments)
        #expect(!style.isMinified)
    }

    @Test("package.json: four spaces, compact colon, inline array, final newline")
    func packageStyle() throws {
        let style = JSONStyle.detect(try JSONDocument.parse(Fixtures.packageJSON))
        #expect(style.indentUnit == "    ")
        #expect(style.keySeparator == ": ")
        #expect(style.endsWithNewline)
        #expect(style.inlineArrays == 1)
        #expect(style.multilineObjects == 2)
        #expect(style.keyOrder == .notApplicable || style.keyOrder == .unsorted)
    }

    @Test("Tabs are one indentation step")
    func tabStyle() throws {
        let style = JSONStyle.detect(try JSONDocument.parse(Fixtures.tabs))
        #expect(style.indentUnit == "\t")
        #expect(style.indent(depth: 2) == "\t\t")
    }

    @Test("CRLF is detected")
    func crlfStyle() throws {
        let style = JSONStyle.detect(try JSONDocument.parse(Fixtures.crlf))
        #expect(style.lineEnding == "\r\n")
        #expect(style.endsWithNewline)
    }

    @Test("A minified file has no indent and no separator spaces")
    func minifiedStyle() throws {
        let style = JSONStyle.detect(try JSONDocument.parse(Fixtures.minified))
        #expect(style.isMinified)
        #expect(style.indentUnit == nil)
        #expect(style.keySeparator == ":")
        #expect(style.multilineObjects == 0)
    }

    @Test("Comments and trailing commas show up in the style")
    func jsoncStyle() throws {
        let style = JSONStyle.detect(try JSONDocument.parse(Fixtures.tsconfig))
        #expect(style.hasComments)
        #expect(style.hasTrailingCommas)
        #expect(style.indentUnit == "  ")
    }

    @Test("Escaping of non-ASCII characters")
    func nonASCII() throws {
        let escaped = JSONStyle.detect(try JSONDocument.parse(#"{"a":"\u0416\u0417"}"#))
        #expect(escaped.escapesNonASCII)
        let raw = JSONStyle.detect(try JSONDocument.parse("{\"a\":\"Жук\"}"))
        #expect(!raw.escapesNonASCII)
    }

    @Test("Key order: sorted, sorted ignoring case, unsorted, mixed")
    func keyOrder() throws {
        let sorted = try JSONDocument.parse(#"{"a":1,"b":2,"c":3}"#)
        #expect(JSONStyle.detect(sorted).keyOrder == .sorted)
        let caseInsensitive = try JSONDocument.parse(#"{"a":1,"B":2,"c":3}"#)
        #expect(JSONStyle.detect(caseInsensitive).keyOrder == .sortedIgnoringCase)
        let unsorted = try JSONDocument.parse(#"{"c":1,"a":2,"b":3}"#)
        #expect(JSONStyle.detect(unsorted).keyOrder == .unsorted)
        let mixed = try JSONDocument.parse(#"{"x":{"a":1,"b":2,"c":3},"y":{"c":1,"a":2,"b":3}}"#)
        #expect(JSONStyle.detect(mixed).keyOrder == .mixed)
        let tiny = try JSONDocument.parse(#"{"b":1,"a":2}"#)
        #expect(JSONStyle.detect(tiny).keyOrder == .notApplicable)
    }

    @Test("Per-object order check")
    func isSorted() throws {
        let doc = try JSONDocument.parse(#"{"x":{"a":1,"b":2},"y":{"b":1,"a":2}}"#)
        let x = try #require(doc.member("x", of: doc.root))
        let y = try #require(doc.member("y", of: doc.root))
        #expect(JSONStyle.isSorted(object: x, in: doc))
        #expect(!JSONStyle.isSorted(object: y, in: doc))
    }

    @Test("An unsorted file keeps the order it has")
    func xcstringsKeyOrder() throws {
        let style = JSONStyle.detect(try JSONDocument.parse(Fixtures.xcstrings))
        // Top-level and inner objects are in ascending order here.
        #expect(style.keyOrder == .sorted || style.keyOrder == .sortedIgnoringCase)
    }
}
