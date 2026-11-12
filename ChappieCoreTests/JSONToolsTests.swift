// JSONToolsTests.swift
// ChappieCoreTests
//
// json_info / json_schema / json_get / json_find (pass J2): paths, the four reports,
// and the promise that no answer outgrows its limit.

import Testing
import Foundation
@testable import ChappieCore

/// A string catalog in Xcode's layout: `count` keys, every third one without Russian,
/// one with a plural variation, one with a comment, one with a different state.
private enum Catalog {
    static func make(count: Int = 300) -> String {
        var entries: [String] = []
        for number in 0..<count {
            let key = "key.\(String(format: "%03d", number))"
            var localizations = "        \"en\" : {\n          \"stringUnit\" : {\n            \"state\" : \"translated\",\n            \"value\" : \"Value \(number)\"\n          }\n        }"
            if number % 3 != 0 {
                let state = number % 7 == 0 ? "needs_review" : "translated"
                localizations += ",\n        \"ru\" : {\n          \"stringUnit\" : {\n            \"state\" : \"\(state)\",\n            \"value\" : \"Значение \(number)\"\n          }\n        }"
            }
            var body = "      \"localizations\" : {\n\(localizations)\n      }"
            if number == 5 { body = "      \"comment\" : \"shown on the button\",\n" + body }
            entries.append("    \"\(key)\" : {\n\(body)\n    }")
        }
        entries.append("""
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
                      },
                      "other" : {
                        "stringUnit" : {
                          "state" : "translated",
                          "value" : "%lld files"
                        }
                      }
                    }
                  }
                }
              }
            }
        """.replacingOccurrences(of: "\n    ", with: "\n"))
        return "{\n  \"sourceLanguage\" : \"en\",\n  \"strings\" : {\n" + entries.joined(separator: ",\n") + "\n  },\n  \"version\" : \"1.0\"\n}"
    }
}

private func run(_ tool: String, _ text: String, _ args: [String: String] = [:], name: String = "Localizable.xcstrings") -> String {
    JSONToolEngine.run(tool: tool, data: Data(text.utf8), fileName: name, arguments: args)
}

// MARK: - Paths

@Suite("JSON paths")
struct JSONPathTests {

    @Test("A path is an array; keys with dots stay whole")
    func arrayPath() throws {
        let doc = try JSONDocument.parse(#"{"chat.send.title":{"ru":"x"},"a":[10,20,30]}"#)
        let hit = doc.resolve(try JSONPathSegment.parseList(#"["chat.send.title","ru"]"#, argument: "at"))
        #expect(hit.count == 1)
        #expect(doc.stringValue(of: hit[0]) == "x")
        #expect(doc.rawText(of: try #require(doc.resolve(try JSONPathSegment.parseList(#"["a",-1]"#, argument: "at")).first)) == "30")
    }

    @Test("Glob: * and ? match, an escaped one is literal")
    func globs() throws {
        let doc = try JSONDocument.parse(#"{"add_a":1,"add_b":2,"other":3,"a*b":4}"#)
        #expect(doc.resolve([.make("add_*")]).count == 2)
        #expect(doc.resolve([.make("add_?")]).count == 2)
        #expect(doc.resolve([.make("*")]).count == 4)
        #expect(doc.resolve([.make(#"a\*b"#)]).count == 1)
        #expect(doc.resolve([.make("o*r")]).count == 1)
        #expect(doc.resolve([.make("*x*")]).isEmpty)
    }

    @Test("** reaches the node and everything below it")
    func anyDepth() throws {
        let doc = try JSONDocument.parse(#"{"a":{"title":1,"b":{"title":2}},"title":3}"#)
        let titles = doc.resolve([.anyDepth, .make("title")])
        #expect(titles.count == 3)
    }

    @Test("path(of:) round-trips through resolve")
    func roundTrip() throws {
        let doc = try JSONDocument.parse(#"{"x":[{"y":1},{"y":2}]}"#)
        for index in doc.nodes.indices {
            #expect(doc.resolve(doc.path(of: index)) == [index])
        }
    }

    @Test("A bad path argument explains the format")
    func badPath() {
        #expect(throws: JSONToolError.self) { try JSONPathSegment.parseList("strings.ru", argument: "at") }
        #expect(throws: JSONToolError.self) { try JSONPathSegment.parseList("[true]", argument: "at") }
    }

    @Test("Rendered path can be pasted back")
    func render() throws {
        let segments: [JSONPathSegment] = [.key("a.b"), .index(2), .key("x*y")]
        let text = JSONPathSegment.render(segments)
        let back = try JSONPathSegment.parseList(text, argument: "at")
        let doc = try JSONDocument.parse(#"{"a.b":[0,1,{"x*y":7}]}"#)
        #expect(doc.resolve(back).count == 1)
    }
}

// MARK: - json_info

@Suite("json_info")
struct JSONInfoTests {

    @Test("Reports size, structure and the Xcode style")
    func catalogInfo() {
        let out = run("json_info", Catalog.make())
        #expect(out.contains("Localizable.xcstrings"))
        #expect(out.contains("Root: object, 3 keys"))
        #expect(out.contains("\"strings\": object, 301 keys"))
        #expect(out.contains("between key and value: \" : \""))
        #expect(out.contains("indent: 2 spaces"))
        #expect(out.contains("no newline at the end"))
        #expect(out.contains("Largest containers"))
    }

    @Test("Notes comments and a BOM")
    func commentsAndBOM() {
        let out = JSONToolEngine.run(
            tool: "json_info", data: Data([0xEF, 0xBB, 0xBF] + Array("{\n  // c\n  \"a\": 1,\n}\n".utf8)),
            fileName: "tsconfig.json", arguments: [:]
        )
        #expect(out.contains("with BOM"))
        #expect(out.contains("comments"))
        #expect(out.contains("trailing commas"))
    }

    @Test("A minified file is described as such")
    func minified() {
        #expect(run("json_info", #"{"a":[1,2],"b":{"c":null}}"#).contains("minified"))
    }
}

// MARK: - json_schema

@Suite("json_schema")
struct JSONSchemaTests {

    @Test("A map of 300 entries is a dictionary described once")
    func dictionary() {
        let out = run("json_schema", Catalog.make())
        #expect(out.contains("dictionary, 301 entries"))
        #expect(out.contains("keys, e.g.: \"key.000\""))
        #expect(!out.contains("key.250"))
        #expect(out.contains("\"ru\""))
        #expect(out.contains("optional"))
    }

    @Test("Optional fields show how many and where the first one is")
    func optionalWithExample() {
        let out = run("json_schema", Catalog.make(), ["at": #"["strings","*"]"#])
        #expect(out.contains("\"comment\""))
        #expect(out.contains("optional, in 1 of 301"))
        #expect(out.contains("first at [\"strings\", \"key.005\", \"comment\"]"))
    }

    @Test("Plural variations are visible in the shape")
    func variations() {
        let out = run("json_schema", Catalog.make(), ["at": #"["strings","*","localizations","*"]"#])
        #expect(out.contains("\"variations\""))
        #expect(out.contains("\"plural\""))
    }

    @Test("Several kinds in one field become a variant with an example place")
    func variant() {
        let out = run("json_schema", #"{"items":[{"v":1},{"v":"x"},{"v":null},{"v":2}]}"#)
        #expect(out.contains("integer"))
        #expect(out.contains("string"))
        #expect(out.contains("e.g. at"))
    }

    @Test("Few distinct strings are listed as the allowed values")
    func enums() {
        let out = run("json_schema", #"[{"s":"a"},{"s":"b"},{"s":"a"},{"s":"c"}]"#)
        #expect(out.contains("one of \"a\", \"b\", \"c\""))
    }

    @Test("A path that does not exist is explained")
    func missing() {
        let out = run("json_schema", Catalog.make(), ["at": #"["strngs"]"#])
        #expect(out.hasPrefix("Error:"))
        #expect(out.contains("strings"))
    }
}

// MARK: - json_get

@Suite("json_get")
struct JSONGetTests {

    @Test("A small part comes back as the file's own numbered lines")
    func rawLines() {
        let out = run("json_get", Catalog.make(), ["at": #"["strings","key.001"]"#])
        #expect(out.contains("\"key.001\" : {"))
        #expect(out.contains("\"value\" : \"Value 1\""))
        #expect(out.contains("L"))
    }

    @Test("The whole big file is collapsed, never dumped")
    func wholeFile() {
        let text = Catalog.make(count: 2000)
        let out = run("json_get", text)
        #expect(out.utf8.count < 9_500)
        #expect(out.contains("Collapsed view"))
        #expect(out.contains("1,9"))   // "… 1,9xx more"
        #expect(out.contains("// L"))
    }

    @Test("max_chars is a hard ceiling for every size of file")
    func ceiling() {
        let text = Catalog.make(count: 3000)
        for limit in [1000, 3000, 8000] {
            let out = run("json_get", text, ["max_chars": String(limit)])
            #expect(out.utf8.count < limit + 600, "limit \(limit) gave \(out.utf8.count)")
        }
    }

    @Test("A wrong key lists what exists, closest first")
    func wrongKey() {
        let out = run("json_get", Catalog.make(), ["at": #"["strings","key.99"]"#])
        #expect(out.hasPrefix("Error:"))
        #expect(out.contains("The path works up to [\"strings\"]"))
        #expect(out.contains("key.0"))
    }

    @Test("A wildcard that matches many places lists them instead of dumping content")
    func wildcard() {
        let out = run("json_get", Catalog.make(), ["at": #"["strings","*","localizations","ru","stringUnit","value"]"#])
        #expect(out.contains("matches"))
        #expect(out.contains("Значение"))
        #expect(out.utf8.count < 9_000)
    }

    @Test("A string longer than the limit is shortened")
    func longString() {
        let big = "{\"s\":\"" + String(repeating: "a", count: 50_000) + "\"}"
        let out = run("json_get", big, ["at": #"["s"]"#])
        #expect(out.utf8.count < 9_000)
    }

    @Test("depth forces the collapsed view")
    func depth() {
        let out = run("json_get", Catalog.make(count: 10), ["depth": "1"])
        #expect(out.contains("Collapsed view (depth 1)"))
    }
}

// MARK: - json_find

@Suite("json_find")
struct JSONFindTests {

    @Test("Entries without a Russian translation: the question search_in_file cannot answer")
    func absence() {
        let out = run("json_find", Catalog.make(), [
            "at": #"["strings","*"]"#, "missing": #"["localizations","ru"]"#, "output": "keys", "limit": "5"
        ])
        // 100 of the 300 numbered entries (every third) plus "%lld files", which has no ru either.
        #expect(out.contains("101 match"))
        #expect(out.contains("\"key.000\", \"key.003\""))
        #expect(out.contains("96 more"))
    }

    @Test("Count mode lists nothing")
    func count() {
        let out = run("json_find", Catalog.make(), [
            "at": #"["strings","*"]"#, "has": #"["localizations","ru"]"#, "output": "count"
        ])
        #expect(out.contains("200 match"))
        #expect(!out.contains("key."))
    }

    @Test("not_equals on a nested value finds the states that are not done")
    func notEquals() {
        let out = run("json_find", Catalog.make(), [
            "at": #"["strings","*","localizations","*"]"#,
            "value_at": #"["stringUnit","state"]"#, "not_equals": "translated", "output": "count"
        ])
        // ru entries that are not translated, plus the "%lld files" en entry: it has no stringUnit
        // state at all, and a subject with no value at value_at passes not_equals.
        let expected = (0..<300).filter { $0 % 3 != 0 && $0 % 7 == 0 }.count + 1
        #expect(out.contains("\(expected) match"))
    }

    @Test("equals and contains compare decoded strings")
    func equalsContains() {
        let eq = run("json_find", Catalog.make(), ["at": #"["strings","*","localizations","ru","stringUnit"]"#, "value_at": #"["value"]"#, "equals": "Значение 10"])
        #expect(eq.contains("1 match"))
        let part = run("json_find", Catalog.make(), ["at": #"["strings","*","localizations","ru","stringUnit"]"#, "value_at": #"["value"]"#, "contains": "значение 299", "ignore_case": "true", "output": "count"])
        #expect(part.contains("1 match"))
    }

    @Test("key glob over every depth, paths carry line numbers")
    func keyGlob() {
        let out = run("json_find", Catalog.make(count: 10), ["at": #"["**"]"#, "key": "plur*"])
        #expect(out.contains("1 match"))
        #expect(out.contains("\"plural\""))
        #expect(out.contains("// L"))
    }

    @Test("kind filter and show print a value beside each path")
    func kindAndShow() {
        let out = run("json_find", Catalog.make(count: 10), [
            "at": #"["strings","*","localizations","ru","stringUnit"]"#, "kind": "object", "show": #"["value"]"#, "limit": "2"
        ])
        #expect(out.contains("→ \"Значение 1\""))
    }

    @Test("group_by counts subjects per value")
    func groupBy() {
        let out = run("json_find", Catalog.make(), [
            "at": #"["strings","*","localizations","ru"]"#, "group_by": #"["stringUnit","state"]"#
        ])
        #expect(out.contains("\"translated\""))
        #expect(out.contains("\"needs_review\""))
    }

    @Test("No condition says so instead of silently returning everything")
    func noCondition() {
        let out = run("json_find", #"{"a":1}"#, ["at": #"["zzz"]"#])
        #expect(out.hasPrefix("Error:"))
    }

    @Test("A huge number of matches stays inside the limit")
    func manyMatches() {
        let out = run("json_find", Catalog.make(count: 3000), ["at": #"["**"]"#, "kind": "string", "limit": "500"])
        #expect(out.utf8.count < 9_000)
        #expect(out.contains("match"))
    }

    @Test("Bad arguments are explained")
    func badArguments() {
        #expect(run("json_find", "{}", ["kind": "text"]).hasPrefix("Error:"))
        #expect(run("json_find", "{}", ["output": "everything"]).hasPrefix("Error:"))
        #expect(run("json_find", "{}", ["limit": "many"]).hasPrefix("Error:"))
    }
}

// MARK: - Engine

@Suite("JSON tools: files that are not plain JSON")
struct JSONEngineEdgeTests {

    @Test("Invalid JSON gives the position")
    func invalid() {
        let out = run("json_info", "{\n  \"a\": 1,\n  \"b\": }\n")
        #expect(out.hasPrefix("Error:"))
        #expect(out.contains("line 3"))
    }

    @Test("UTF-16 is named, not misreported")
    func utf16() {
        let data = Data([0xFF, 0xFE, 0x7B, 0x00, 0x7D, 0x00])
        let out = JSONToolEngine.run(tool: "json_info", data: data, fileName: "x.json", arguments: [:])
        #expect(out.contains("UTF-16"))
    }

    @Test("A very deep document does not overflow the stack on a worker thread")
    func deep() async {
        let text = String(repeating: "[", count: 500) + String(repeating: "]", count: 500)
        let outputs = await Task.detached { () -> [String] in
            ["json_info", "json_schema", "json_get", "json_find"].map {
                JSONToolEngine.run(tool: $0, data: Data(text.utf8), fileName: "deep.json", arguments: $0 == "json_find" ? ["at": #"["**"]"#, "kind": "array", "output": "count"] : [:])
            }
        }.value
        for out in outputs { #expect(!out.hasPrefix("Error: Unknown")) }
        #expect(outputs[3].contains("500 match"))
    }

    @Test("An empty file and a scalar root work")
    func degenerate() {
        #expect(run("json_info", "").hasPrefix("Error:"))
        #expect(run("json_get", "42").contains("42"))
        #expect(run("json_schema", "[]").contains("array"))
    }

    @Test("Unknown tool name is reported")
    func unknown() {
        #expect(run("json_nope", "{}").hasPrefix("Error: Unknown"))
    }
}

// MARK: - Through the tool service

@Suite("json_* through ToolExecutionService")
struct JSONToolServiceTests {

    @Test("All four are classified as project reads and ordered")
    func policy() {
        for name in JSONToolEngine.toolNames {
            #expect(ToolPolicy.capability(of: name) == .fileRead)
            #expect(ToolPolicy.dangerRank(of: name) < ToolPolicy.dangerRank(of: "write_file"))
        }
    }

    @Test("The file is read through the project and answered")
    func endToEnd() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("json-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Catalog.make(count: 50).write(to: dir.appendingPathComponent("L.xcstrings"), atomically: true, encoding: .utf8)

        let service = ToolExecutionService(
            fileSystem: FileSystemManager(workspaces: [(name: "P", url: dir)]),
            memoryManager: MemoryManager(workspaceURL: dir),
            socketPath: "/tmp/chappie-json-tests-nonexistent.sock"
        )
        let reply = await service.executeJSONTool(name: "json_info", argsData: Data(#"{"path":"L.xcstrings","project":"P"}"#.utf8))
        #expect(reply.contains("Root: object, 3 keys"))

        let outside = await service.executeJSONTool(name: "json_info", argsData: Data(#"{"path":"../x.json","project":"P"}"#.utf8))
        #expect(outside.hasPrefix("Error:"))

        let missing = await service.executeJSONTool(name: "json_get", argsData: Data(#"{"path":"nope.json","project":"P"}"#.utf8))
        #expect(missing.hasPrefix("Error:"))
    }
}
