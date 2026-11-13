// JSONEditTests.swift
// ChappieCoreTests
//
// json_edit (pass J3): in-place byte edits. The promises under test: bytes outside the edited places
// never change, new fragments copy the file's style, any problem means nothing is written.

import Testing
import Foundation
@testable import ChappieCore

private func edit(_ text: String, _ edits: String, dry: Bool = false) -> (text: String, result: String?) {
    let outcome = JSONEditEngine.run(
        data: Data(text.utf8), fileName: "f.json", editsText: edits, dryRun: dry, maxChars: JSONOutput.defaultChars
    )
    return (outcome.text, outcome.newData.map { String(decoding: $0, as: UTF8.self) })
}

/// The new file text, or a test failure that shows the engine's answer.
private func applied(_ text: String, _ edits: String) -> String {
    let (answer, result) = edit(text, edits)
    #expect(result != nil, "\(answer)")
    return result ?? ""
}

// MARK: - set

@Suite("json_edit: set")
struct JSONEditSetTests {

    private let file = "{\n  \"a\" : 1,\n  \"b\" : {\n    \"c\" : \"x\"\n  },\n  \"d\" : [1, 2]\n}\n"

    @Test("Only the value changes, every other byte stays")
    func scalar() {
        let result = applied(file, #"[{"op":"set","at":["a"],"value":42}]"#)
        #expect(result == file.replacingOccurrences(of: "\"a\" : 1", with: "\"a\" : 42"))
    }

    @Test("A string is written with the file's escaping")
    func escaping() {
        let slashes = "{\n  \"u\" : \"a\\/b\"\n}"
        #expect(applied(slashes, #"[{"op":"set","at":["u"],"value":"x/y"}]"#).contains("\"x\\/y\""))
        let plain = "{\n  \"u\" : \"a/b\"\n}"
        #expect(applied(plain, #"[{"op":"set","at":["u"],"value":"x/y"}]"#).contains("\"x/y\""))
        let escaped = "{\"u\":\"\\u00e9\"}"
        #expect(applied(escaped, #"[{"op":"set","at":["u"],"value":"Привет"}]"#).contains("\\u041f"))
        let raw = "{\"u\":\"é\"}"
        #expect(applied(raw, #"[{"op":"set","at":["u"],"value":"Привет"}]"#).contains("Привет"))
    }

    @Test("A new object copies the file's multiline layout and separator")
    func objectStyle() {
        let result = applied(file, #"[{"op":"set","at":["b"],"value":{"p":1,"q":[true,null]}}]"#)
        #expect(result.contains("\"b\" : {\n    \"p\" : 1,\n    \"q\" : [true, null]\n  },"))
    }

    @Test("A tab-indented, CRLF file stays tab-indented and CRLF")
    func tabsAndCRLF() {
        let text = "{\r\n\t\"a\": 1,\r\n\t\"b\": 2\r\n}\r\n"
        let result = applied(text, #"[{"op":"set","at":["b"],"value":{"x":1}}]"#)
        #expect(result == "{\r\n\t\"a\": 1,\r\n\t\"b\": {\r\n\t\t\"x\": 1\r\n\t}\r\n}\r\n")
    }

    @Test("A minified file stays on one line")
    func minified() {
        let result = applied(#"{"a":1,"b":[1,2]}"#, #"[{"op":"set","at":["b"],"value":{"x":[1,2]}}]"#)
        #expect(result == #"{"a":1,"b":{"x":[1,2]}}"#)
    }

    @Test("Setting the same value changes nothing and writes nothing")
    func noChange() {
        let (answer, result) = edit(file, #"[{"op":"set","at":["a"],"value":1}]"#)
        #expect(result == nil)
        #expect(answer.hasPrefix("No change"))
    }

    @Test("expect guards against a file that moved on")
    func expectGuard() {
        let ok = applied(file, #"[{"op":"set","at":["a"],"expect":1,"value":2}]"#)
        #expect(ok.contains("\"a\" : 2"))
        let (answer, result) = edit(file, #"[{"op":"set","at":["a"],"expect":99,"value":2}]"#)
        #expect(result == nil)
        #expect(answer.contains("not what 'expect' says"))
    }

    @Test("expect ignores formatting and key order")
    func expectStructural() {
        let ok = applied(file, #"[{"op":"set","at":["b"],"expect":{"c":"x"},"value":0}]"#)
        #expect(ok.contains("\"b\" : 0"))
    }

    @Test("A missing key suggests insert")
    func missingKey() {
        let (answer, result) = edit(file, #"[{"op":"set","at":["b","zzz"],"value":1}]"#)
        #expect(result == nil)
        #expect(answer.contains("insert"))
    }

    @Test("A wildcard that hits many places is refused")
    func ambiguous() {
        let (answer, result) = edit(file, #"[{"op":"set","at":["*"],"value":1}]"#)
        #expect(result == nil)
        #expect(answer.contains("exactly one"))
    }

    @Test("Comments around the value survive")
    func comments() {
        let text = "{\n  // keep\n  \"a\": 1, /* c */\n  \"b\": 2\n}\n"
        let result = applied(text, #"[{"op":"set","at":["a"],"value":9}]"#)
        #expect(result == text.replacingOccurrences(of: "\"a\": 1", with: "\"a\": 9"))
    }

    @Test("The BOM is preserved")
    func bom() {
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("{\"a\":1}".utf8)
        let outcome = JSONEditEngine.run(data: bytes, fileName: "f.json", editsText: #"[{"op":"set","at":["a"],"value":2}]"#, dryRun: false, maxChars: 8000)
        #expect(outcome.newData?.prefix(3) == Data([0xEF, 0xBB, 0xBF]))
    }
}

// MARK: - insert

@Suite("json_edit: insert")
struct JSONEditInsertTests {

    private let sorted = "{\n  \"a\" : 1,\n  \"c\" : 3,\n  \"e\" : 5\n}"
    private let unsorted = "{\n  \"z\" : 1,\n  \"a\" : 2,\n  \"m\" : 3\n}"

    @Test("auto keeps an alphabetical object alphabetical")
    func autoSorted() {
        let result = applied(sorted, #"[{"op":"insert","at":[],"key":"d","value":4}]"#)
        #expect(result == "{\n  \"a\" : 1,\n  \"c\" : 3,\n  \"d\" : 4,\n  \"e\" : 5\n}")
    }

    @Test("auto appends to an object that is not alphabetical")
    func autoAppends() {
        let result = applied(unsorted, #"[{"op":"insert","at":[],"key":"b","value":4}]"#)
        #expect(result == "{\n  \"z\" : 1,\n  \"a\" : 2,\n  \"m\" : 3,\n  \"b\" : 4\n}")
    }

    @Test("start, end, after and before")
    func positions() {
        #expect(applied(unsorted, #"[{"op":"insert","at":[],"key":"k","value":0,"position":"start"}]"#).hasPrefix("{\n  \"k\" : 0,\n  \"z\""))
        #expect(applied(unsorted, #"[{"op":"insert","at":[],"key":"k","value":0,"position":{"after":"z"}}]"#).contains("\"z\" : 1,\n  \"k\" : 0,\n  \"a\""))
        #expect(applied(unsorted, #"[{"op":"insert","at":[],"key":"k","value":0,"position":{"before":"m"}}]"#).contains("\"a\" : 2,\n  \"k\" : 0,\n  \"m\""))
        #expect(applied(unsorted, #"[{"op":"insert","at":[],"key":"k","value":0,"position":"end"}]"#).hasSuffix("\"k\" : 0\n}"))
    }

    @Test("sorted on an unsorted object is refused")
    func sortedRefused() {
        let (answer, result) = edit(unsorted, #"[{"op":"insert","at":[],"key":"b","value":4,"position":"sorted"}]"#)
        #expect(result == nil)
        #expect(answer.contains("alphabetical"))
    }

    @Test("Several keys into one place get their commas and order right")
    func severalAtOnce() {
        let result = applied(sorted, #"[{"op":"insert","at":[],"key":"d","value":4},{"op":"insert","at":[],"key":"b","value":2},{"op":"insert","at":[],"key":"z","value":26}]"#)
        #expect(result == "{\n  \"a\" : 1,\n  \"b\" : 2,\n  \"c\" : 3,\n  \"d\" : 4,\n  \"e\" : 5,\n  \"z\" : 26\n}")
    }

    @Test("Into an empty object, written like the file writes empties")
    func intoEmpty() {
        let xcode = "{\n  \"a\" : {\n\n  },\n  \"b\" : {\n\n  }\n}"
        let result = applied(xcode, #"[{"op":"insert","at":["a"],"key":"x","value":1}]"#)
        #expect(result == "{\n  \"a\" : {\n    \"x\" : 1\n  },\n  \"b\" : {\n\n  }\n}")
        let compact = applied(#"{"a":{}}"#, #"[{"op":"insert","at":["a"],"key":"x","value":1}]"#)
        #expect(compact == #"{"a":{"x":1}}"#)
    }

    @Test("A duplicate key is refused, with a pointer to set")
    func duplicate() {
        let (answer, result) = edit(sorted, #"[{"op":"insert","at":[],"key":"a","value":9}]"#)
        #expect(result == nil)
        #expect(answer.contains("already exists"))
        #expect(answer.contains("set"))
        let (twice, none) = edit(sorted, #"[{"op":"insert","at":[],"key":"q","value":1},{"op":"insert","at":[],"key":"q","value":2}]"#)
        #expect(none == nil)
        #expect(twice.contains("also inserts"))
    }

    @Test("Array items: end by default, at a position")
    func arrays() {
        let text = "{\n  \"l\" : [\n    1,\n    3\n  ]\n}"
        #expect(applied(text, #"[{"op":"insert","at":["l"],"value":4}]"#) == "{\n  \"l\" : [\n    1,\n    3,\n    4\n  ]\n}")
        #expect(applied(text, #"[{"op":"insert","at":["l"],"value":2,"position":1}]"#) == "{\n  \"l\" : [\n    1,\n    2,\n    3\n  ]\n}")
        #expect(applied("[1,2]", #"[{"op":"insert","at":[],"value":0,"position":"start"}]"#) == "[0,1,2]")
        let (answer, result) = edit(text, #"[{"op":"insert","at":["l"],"key":"k","value":1}]"#)
        #expect(result == nil)
        #expect(answer.contains("no key"))
    }

    @Test("A negative position counts from the end, like a path segment")
    func negativePosition() {
        let text = "{\n  \"l\" : [\n    1,\n    2,\n    3\n  ]\n}"
        #expect(applied(text, #"[{"op":"insert","at":["l"],"value":0,"position":-1}]"#) == "{\n  \"l\" : [\n    1,\n    2,\n    0,\n    3\n  ]\n}")
        #expect(applied(text, #"[{"op":"insert","at":["l"],"value":0,"position":-3}]"#) == "{\n  \"l\" : [\n    0,\n    1,\n    2,\n    3\n  ]\n}")
        // -count is the first place, so one past the end has no negative form.
        let (answer, result) = edit(text, #"[{"op":"insert","at":["l"],"value":0,"position":-4}]"#)
        #expect(result == nil)
        #expect(answer.contains("outside"))
        #expect(answer.contains("-1...-3"))
    }

    @Test("Key rules: needed for objects, forbidden for arrays, insert into a scalar refused")
    func keyRules() {
        #expect(edit(sorted, #"[{"op":"insert","at":[],"value":1}]"#).result == nil)
        #expect(edit(sorted, #"[{"op":"insert","at":["a"],"key":"x","value":1}]"#).result == nil)
    }

    @Test("after/before on an array says the array has no keys, instead of looking for one")
    func anchorOnArray() {
        let text = "{\n  \"l\" : [\n    1,\n    2\n  ]\n}"
        let (answer, result) = edit(text, #"[{"op":"insert","at":["l"],"value":0,"position":{"after":"beta"}}]"#)
        #expect(result == nil)
        #expect(answer.contains("array item has no key"))
        #expect(!answer.contains("not in this object"))
    }

    @Test("A comment at the insertion point is refused, not silently reattached")
    func commentRefused() {
        let text = "{\n  \"a\": 1,\n  // about b\n  \"b\": 2\n}"
        let (answer, result) = edit(text, #"[{"op":"insert","at":[],"key":"x","value":0,"position":{"before":"b"}}]"#)
        #expect(result == nil)
        #expect(answer.contains("comment"))
        // Appending at the end does not touch the comment.
        #expect(edit(text, #"[{"op":"insert","at":[],"key":"x","value":0}]"#).result != nil)
    }
}

// MARK: - delete

@Suite("json_edit: delete")
struct JSONEditDeleteTests {

    private let file = "{\n  \"a\" : 1,\n  \"b\" : 2,\n  \"c\" : 3,\n  \"d\" : 4\n}"

    @Test("Middle, first and last member")
    func positions() {
        #expect(applied(file, #"[{"op":"delete","at":["b"]}]"#) == "{\n  \"a\" : 1,\n  \"c\" : 3,\n  \"d\" : 4\n}")
        #expect(applied(file, #"[{"op":"delete","at":["a"]}]"#) == "{\n  \"b\" : 2,\n  \"c\" : 3,\n  \"d\" : 4\n}")
        #expect(applied(file, #"[{"op":"delete","at":["d"]}]"#) == "{\n  \"a\" : 1,\n  \"b\" : 2,\n  \"c\" : 3\n}")
    }

    @Test("A run of neighbours and a run that reaches the end")
    func runs() {
        #expect(applied(file, #"[{"op":"delete","at":["b"]},{"op":"delete","at":["c"]}]"#) == "{\n  \"a\" : 1,\n  \"d\" : 4\n}")
        #expect(applied(file, #"[{"op":"delete","at":["c"]},{"op":"delete","at":["d"]}]"#) == "{\n  \"a\" : 1,\n  \"b\" : 2\n}")
        #expect(applied(file, #"[{"op":"delete","at":["a"]},{"op":"delete","at":["c"]}]"#) == "{\n  \"b\" : 2,\n  \"d\" : 4\n}")
    }

    @Test("Deleting everything leaves an empty container in the file's own form")
    func everything() {
        let all = #"[{"op":"delete","at":["a"]},{"op":"delete","at":["b"]},{"op":"delete","at":["c"]},{"op":"delete","at":["d"]}]"#
        // This file has no empty object of its own, so the compact form is used.
        #expect(applied(file, all) == "{}")
        #expect(applied(#"{"a":1}"#, #"[{"op":"delete","at":["a"]}]"#) == "{}")
        let nested = "{\n  \"o\" : {\n    \"x\" : 1\n  },\n  \"e\" : {\n\n  }\n}"
        #expect(applied(nested, #"[{"op":"delete","at":["o","x"]}]"#) == "{\n  \"o\" : {\n\n  },\n  \"e\" : {\n\n  }\n}")
    }

    @Test("Array items are removed by position, negative counts from the end")
    func arrayItems() {
        #expect(applied("[1, 2, 3]", #"[{"op":"delete","at":[1]}]"#) == "[1, 3]")
        #expect(applied("[1, 2, 3]", #"[{"op":"delete","at":[-1]}]"#) == "[1, 2]")
    }

    @Test("A comment next to the member stops the delete")
    func commentRefused() {
        let text = "{\n  \"a\": 1, // first\n  \"b\": 2\n}"
        let (answer, result) = edit(text, #"[{"op":"delete","at":["a"]}]"#)
        #expect(result == nil)
        #expect(answer.contains("comment"))
    }

    @Test("The root cannot be deleted; the same value twice is caught")
    func guards() {
        #expect(edit(file, #"[{"op":"delete","at":[]}]"#).result == nil)
        let (answer, result) = edit(file, #"[{"op":"delete","at":["a"]},{"op":"delete","at":["a"]}]"#)
        #expect(result == nil)
        #expect(answer.contains("already deletes"))
    }

    @Test("Delete and set in one call use the original paths")
    func originalPaths() {
        let text = "{\n  \"l\" : [\n    10,\n    20,\n    30\n  ]\n}"
        let result = applied(text, #"[{"op":"delete","at":["l",0]},{"op":"set","at":["l",2],"value":99}]"#)
        #expect(result == "{\n  \"l\" : [\n    20,\n    99\n  ]\n}")
    }
}

// MARK: - rename

@Suite("json_edit: rename")
struct JSONEditRenameTests {

    @Test("The key changes, the value is untouched")
    func basic() {
        let text = "{\n  \"old\" : {\n    \"x\" : 1\n  }\n}"
        #expect(applied(text, #"[{"op":"rename","at":["old"],"to":"new"}]"#) == "{\n  \"new\" : {\n    \"x\" : 1\n  }\n}")
    }

    @Test("A clash with an existing key is refused; an array item has no key")
    func guards() {
        let text = "{\"a\":1,\"b\":2,\"l\":[1]}"
        #expect(edit(text, #"[{"op":"rename","at":["a"],"to":"b"}]"#).result == nil)
        #expect(edit(text, #"[{"op":"rename","at":["l",0],"to":"b"}]"#).result == nil)
    }

    @Test("Renaming inside an alphabetical object carries a note")
    func sortedNote() {
        let (answer, result) = edit("{\"a\":1,\"b\":2,\"c\":3}", #"[{"op":"rename","at":["a"],"to":"z"}]"#)
        #expect(result != nil)
        #expect(answer.contains("alphabetical"))
    }

    @Test("Paths mean the original file: inserting a key that a rename in the same call frees is refused")
    func renameAndInsert() {
        let (answer, result) = edit("{\"a\":1,\"b\":2}", #"[{"op":"rename","at":["a"],"to":"c"},{"op":"insert","at":[],"key":"a","value":9}]"#)
        #expect(result == nil)
        #expect(answer.contains("already exists"))
        // Two calls do it.
        let step = applied("{\"a\":1,\"b\":2}", #"[{"op":"rename","at":["a"],"to":"c"}]"#)
        #expect(applied(step, #"[{"op":"insert","at":[],"key":"a","value":9}]"#).contains("\"a\":9"))
    }
}

// MARK: - Safety

@Suite("json_edit: safety and reports")
struct JSONEditSafetyTests {

    private let file = "{\"a\":1,\"b\":2}"

    @Test("dry_run reports the change and writes nothing")
    func dryRun() {
        let (answer, result) = edit(file, #"[{"op":"set","at":["a"],"value":5}]"#, dry: true)
        #expect(result == nil)
        #expect(answer.contains("DRY RUN"))
        #expect(answer.contains("+ "))
        #expect(answer.contains("without dry_run"))
    }

    @Test("A real answer shows old and new lines and the proof statement")
    func report() {
        let (answer, result) = edit("{\n  \"a\" : 1\n}", #"[{"op":"set","at":["a"],"value":5}]"#)
        #expect(result != nil)
        #expect(answer.contains("- \"a\" : 1"))
        #expect(answer.contains("+ \"a\" : 5"))
        #expect(answer.contains("Every byte outside"))
    }

    @Test("An insertion never prints a neighbouring line as removed")
    func insertionReport() {
        let text = "{\n  \"a\" : 1,\n  \"zh-Hans\" : 2\n}"
        let (answer, result) = edit(text, #"[{"op":"insert","at":[],"key":"b","value":3,"position":"end"}]"#)
        #expect(result != nil)
        #expect(answer.contains("+ \"b\" : 3"))
        #expect(!answer.contains("- \"zh-Hans\""))
        #expect(!answer.contains("- \""))
    }

    @Test("Two edits on one line are printed once, with both numbers")
    func sharedLineReport() {
        // A minified file puts both members on one line, which is where the merging matters.
        let text = #"{"a":1,"b":2}"#
        let (answer, result) = edit(text, #"[{"op":"set","at":["a"],"value":10},{"op":"set","at":["b"],"value":20}]"#)
        #expect(result != nil)
        #expect(answer.contains("edit 1,2"))
        #expect(answer.contains("- {\"a\":1,\"b\":2}"))
        #expect(answer.contains("+ {\"a\":10,\"b\":20}"))
        // The shared line is printed once, not once per edit.
        #expect(answer.components(separatedBy: "- {\"a\":1,\"b\":2}").count == 2)
    }

    @Test("An insertion in the middle shows what was added, without the comma that glues it in")
    func insertionMiddleReport() {
        let text = "{\n  \"a\" : 1,\n  \"c\" : 3\n}"
        let (answer, result) = edit(text, #"[{"op":"insert","at":[],"key":"b","value":2,"position":{"after":"a"}}]"#)
        #expect(result != nil)
        // The new member is spliced in at the start of the line that holds "c", so that is the line quoted.
        #expect(answer.contains("L3"))
        #expect(answer.contains("+ \"b\" : 2"))
        #expect(!answer.contains("2,"))
        #expect(!answer.contains("- \""))
    }

    @Test("A line the edit only shifted is not printed as removed")
    func commaShift() {
        // Deleting the first member moves the comma away from the line of the second one; the line
        // itself keeps its content, so reporting it as removed would read as lost data.
        let text = "{\n  \"a\" : 1,\n  \"b\" : 2\n}"
        let (answer, result) = edit(text, #"[{"op":"delete","at":["a"]}]"#)
        #expect(result == "{\n  \"b\" : 2\n}")
        #expect(!answer.contains("- \"b\" : 2"))
    }

    @Test("An insertion next to a delete keeps each place to itself")
    func insertBesideDelete() {
        let text = "{\n  \"o\" : {\n    \"keep\" : 1,\n    \"gone\" : 2\n  }\n}"
        let edits = #"[{"op":"delete","at":["o","gone"]},{"op":"insert","at":["o"],"key":"fresh","value":{"x":1},"position":"start"}]"#
        let (answer, result) = edit(text, edits)
        #expect(result != nil)
        #expect(answer.contains("+ \"fresh\" : {"))
        #expect(!answer.contains("- \"keep\""))
    }

    @Test("An unchanged neighbourhood is not shown as rewritten")
    func neighbourhoodTrimmed() {
        let text = "{\n  \"o\" : {\n    \"a\" : 1,\n    \"b\" : 2\n  }\n}"
        let (answer, result) = edit(text, #"[{"op":"set","at":["o","b"],"value":9}]"#)
        #expect(result != nil)
        #expect(answer.contains("- \"b\" : 2"))
        #expect(answer.contains("+ \"b\" : 9"))
        #expect(!answer.contains("\"o\" :"))
    }

    @Test("All problems are listed together, nothing is written")
    func allProblems() {
        let (answer, result) = edit(file, #"[{"op":"set","at":["x"],"value":1},{"op":"delete","at":["y"]},{"op":"set","at":["a"],"expect":7,"value":1}]"#)
        #expect(result == nil)
        #expect(answer.contains("3 problems"))
        #expect(answer.contains("edits[1]"))
        #expect(answer.contains("edits[2]"))
        #expect(answer.contains("edits[3]"))
    }

    @Test("Two edits on the same place are refused")
    func overlap() {
        let (answer, result) = edit(file, #"[{"op":"set","at":["a"],"value":1.5},{"op":"set","at":["a"],"value":2}]"#)
        #expect(result == nil)
        #expect(answer.contains("same place"))
        let (nested, none) = edit(#"{"o":{"x":1}}"#, #"[{"op":"set","at":["o"],"value":0},{"op":"set","at":["o","x"],"value":2}]"#)
        #expect(none == nil)
        #expect(nested.contains("same place"))
    }

    @Test("The operations text is checked: bad JSON, unknown field, unknown op, empty list")
    func badEdits() {
        #expect(edit(file, "[{op:set}]").text.contains("not valid JSON"))
        #expect(edit(file, #"[{"op":"set","at":["a"],"value":1,"valu":2}]"#).text.contains("unknown field 'valu'"))
        #expect(edit(file, #"[{"op":"change","at":["a"]}]"#).text.contains("unknown op"))
        #expect(edit(file, "[]").text.contains("empty"))
        #expect(edit(file, #"[{"op":"set","at":"a","value":1}]"#).text.contains("JSON array"))
        #expect(edit(file, #"[{"op":"set","at":["a"]}]"#).text.contains("'value' is required"))
        #expect(edit(file, #"[{"op":"delete","at":["a"],"value":1}]"#).text.contains("does not apply"))
        #expect(edit(file, #"[{"op":"insert","at":[],"key":"k","value":1,"expect":1}]"#).text.contains("does not apply"))
    }

    @Test("A single operation object is accepted instead of a list")
    func singleObject() {
        #expect(applied(file, #"{"op":"set","at":["a"],"value":3}"#) == #"{"a":3,"b":2}"#)
    }

    @Test("A file that is not valid JSON, or UTF-16, is refused before anything is planned")
    func badFile() {
        #expect(edit("{\"a\":", #"[{"op":"set","at":["a"],"value":1}]"#).text.contains("not valid JSON"))
        let utf16 = JSONEditEngine.run(data: Data([0xFF, 0xFE, 0x7B, 0x00]), fileName: "f.json", editsText: "[]", dryRun: false, maxChars: 8000)
        #expect(utf16.text.contains("UTF-16"))
    }

    @Test("Values nested too deep are refused")
    func deepValue() {
        let value = String(repeating: "[", count: 70) + String(repeating: "]", count: 70)
        #expect(edit(file, #"[{"op":"set","at":["a"],"value":\#(value)}]"#).text.contains("nested deeper"))
    }

    @Test("The outside-bytes check catches a corrupted result")
    func outsideCheck() {
        let original = Array("hello world".utf8)
        let splice = JSONSplice(start: 6, end: 11, text: Array("there".utf8), ops: [1])
        #expect(JSONEditEngine.outsideUntouched(original: original, result: Array("hello there".utf8), ordered: [splice]))
        #expect(!JSONEditEngine.outsideUntouched(original: original, result: Array("jello there".utf8), ordered: [splice]))
    }

    @Test("The verification rejects a result that is not what was asked")
    func verifyRejects() throws {
        let doc = try JSONDocument.parse(#"{"a":1}"#)
        let wanted = try JSONDocument.parse("2")
        let check = JSONEditCheck.value(path: [.key("a")], expected: JSONEditValue(doc: wanted, node: 0), op: 1)
        let splice = JSONSplice(start: 5, end: 6, text: Array("3".utf8), ops: [1])
        let reason = JSONEditEngine.verify(original: doc, result: Array(#"{"a":3}"#.utf8), ordered: [splice], checks: [check])
        #expect(reason?.contains("does not hold") == true)
        let broken = JSONEditEngine.verify(original: doc, result: Array(#"{"a":}"#.utf8), ordered: [JSONSplice(start: 5, end: 6, text: [], ops: [1])], checks: [])
        #expect(broken?.contains("not valid JSON") == true)
    }
}

// MARK: - An Xcode catalog, edited back and forth

@Suite("json_edit: string catalog round trip")
struct JSONEditCatalogTests {

    /// Xcode's layout: indent 2, " : ", "\/" escaped, no newline at the end, empty objects on three lines.
    private static func catalog(count: Int, withRussian: Set<Int>) -> String {
        // "empty" sorts before "key.*", so the catalog is alphabetical like a real one.
        var entries: [String] = ["    \"empty\" : {\n\n    }"]
        for n in 0..<count {
            let key = "key.\(String(format: "%03d", n))"
            var locs = "        \"en\" : {\n          \"stringUnit\" : {\n            \"state\" : \"translated\",\n            \"value\" : \"Open a\\/b \(n)\"\n          }\n        }"
            if withRussian.contains(n) {
                locs += ",\n        \"ru\" : {\n          \"stringUnit\" : {\n            \"state\" : \"translated\",\n            \"value\" : \"Открыть \(n)\"\n          }\n        }"
            }
            entries.append("    \"\(key)\" : {\n      \"localizations\" : {\n\(locs)\n      }\n    }")
        }
        return "{\n  \"sourceLanguage\" : \"en\",\n  \"strings\" : {\n" + entries.joined(separator: ",\n") + "\n  },\n  \"version\" : \"1.0\"\n}"
    }

    @Test("Remove ru from many keys, put it back: the file is byte-identical to the start")
    func roundTrip() {
        let all = Set(0..<60)
        let original = Self.catalog(count: 60, withRussian: all)
        let targets = [3, 4, 5, 17, 29, 59]

        let deletes = targets.map { #"{"op":"delete","at":["strings","key.\#(String(format: "%03d", $0))","localizations","ru"]}"# }
        let stripped = applied(original, "[" + deletes.joined(separator: ",") + "]")
        #expect(stripped == Self.catalog(count: 60, withRussian: all.subtracting(targets)))

        let inserts = targets.map {
            #"{"op":"insert","at":["strings","key.\#(String(format: "%03d", $0))","localizations"],"key":"ru","value":{"stringUnit":{"state":"translated","value":"Открыть \#($0)"}}}"#
        }
        let restored = applied(stripped, "[" + inserts.joined(separator: ",") + "]")
        #expect(restored == original)
    }

    @Test("New catalog keys land in alphabetical place, in one call")
    func newKeys() {
        let text = Self.catalog(count: 10, withRussian: [])
        let entry = #"{"localizations":{"en":{"stringUnit":{"state":"new","value":"Hi"}}}}"#
        let result = applied(text, #"[{"op":"insert","at":["strings"],"key":"key.0045","value":\#(entry)},{"op":"insert","at":["strings"],"key":"aaa","value":\#(entry)}]"#)
        let aaa = result.range(of: "\"aaa\"")!.lowerBound
        let first = result.range(of: "\"key.000\"")!.lowerBound
        let mid = result.range(of: "\"key.0045\"")!.lowerBound
        let key5 = result.range(of: "\"key.005\"")!.lowerBound
        #expect(aaa < first)
        #expect(first < mid && mid < key5)
        #expect(result.contains("\"key.0045\" : {\n      \"localizations\" : {\n        \"en\" : {\n          \"stringUnit\" : {\n            \"state\" : \"new\",\n            \"value\" : \"Hi\"\n"))
    }

    @Test("A big catalog is edited and checked fast")
    func speed() {
        let text = Self.catalog(count: 4000, withRussian: Set(stride(from: 0, to: 4000, by: 2)))
        let start = Date()
        let result = applied(text, #"[{"op":"set","at":["strings","key.001","localizations","en","stringUnit","value"],"value":"changed"}]"#)
        #expect(result.contains("\"value\" : \"changed\""))
        #expect(Date().timeIntervalSince(start) < 5)
    }
}

// MARK: - Through the tool service

@Suite("json_edit through ToolExecutionService")
struct JSONEditServiceTests {

    private func rig() throws -> (ToolExecutionService, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("json-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let service = ToolExecutionService(
            fileSystem: FileSystemManager(workspaces: [(name: "P", url: dir)]),
            memoryManager: MemoryManager(workspaceURL: dir),
            socketPath: "/tmp/chappie-json-edit-nonexistent.sock"
        )
        return (service, dir)
    }

    /// Like the real path: authorization flattens the arguments, the raw text goes alongside.
    private func call(_ service: ToolExecutionService, _ json: String) async -> String {
        guard case .success(let flat) = ToolArguments.parse(json), let data = try? JSONEncoder().encode(flat) else {
            return "test setup: arguments do not parse"
        }
        return await service.executeJSONEdit(argsData: data, rawArgsData: Data(json.utf8))
    }

    @Test("Policy: a write tool, ordered with the other writers")
    func policy() {
        #expect(ToolPolicy.capability(of: "json_edit") == .fileWrite)
        #expect(ToolDeadlines.isMutating("json_edit"))
        #expect(ToolPolicy.dangerRank(of: "json_edit") > ToolPolicy.dangerRank(of: "json_find"))
        #expect(ToolPolicy.dangerRank(of: "json_edit") < ToolPolicy.dangerRank(of: "git_status"))
        #expect(!ToolPolicy.decide(tool: "json_edit", project: ProjectSettings(), terminalEnabled: false).isAllowed)
    }

    @Test("The file is edited on disk, and a dry run leaves it alone")
    func endToEnd() async throws {
        let (service, dir) = try rig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.json")
        try "{\n  \"a\" : 1\n}".write(to: url, atomically: true, encoding: .utf8)

        let dry = await call(service, #"{"path":"a.json","project":"P","dry_run":"true","edits":[{"op":"set","at":["a"],"value":2}]}"#)
        #expect(dry.contains("DRY RUN"))
        #expect(try String(contentsOf: url, encoding: .utf8) == "{\n  \"a\" : 1\n}")

        let real = await call(service, #"{"path":"a.json","project":"P","edits":[{"op":"set","at":["a"],"value":2}]}"#)
        #expect(real.contains("Applied"))
        #expect(try String(contentsOf: url, encoding: .utf8) == "{\n  \"a\" : 2\n}")
    }

    @Test("edits may arrive as text, and the key order of a new object is the one the model wrote")
    func keyOrder() async throws {
        let (service, dir) = try rig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.json")
        try "{\"o\":{}}".write(to: url, atomically: true, encoding: .utf8)

        let raw = #"{"path":"a.json","project":"P","edits":[{"op":"insert","at":["o"],"key":"k","value":{"zebra":1,"apple":2}}]}"#
        // The flat map the authorizer builds sorts keys; the raw call keeps the model's order.
        let flat = #"{"path":"a.json","project":"P","edits":"[{\"at\":[\"o\"],\"key\":\"k\",\"op\":\"insert\",\"value\":{\"apple\":2,\"zebra\":1}}]"}"#
        _ = await service.executeJSONEdit(argsData: Data(flat.utf8), rawArgsData: Data(raw.utf8))
        #expect(try String(contentsOf: url, encoding: .utf8) == #"{"o":{"k":{"zebra":1, "apple":2}}}"#.replacingOccurrences(of: ", ", with: ","))

        try "{\"o\":{}}".write(to: url, atomically: true, encoding: .utf8)
        let asText = #"{"path":"a.json","project":"P","edits":"[{\"op\":\"set\",\"at\":[\"o\"],\"value\":5}]"}"#
        _ = await call(service, asText)
        #expect(try String(contentsOf: url, encoding: .utf8) == #"{"o":5}"#)
    }

    @Test("A path outside the project, a missing file and a missing edits argument are errors")
    func errors() async throws {
        let (service, dir) = try rig()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect((await call(service, #"{"path":"../x.json","project":"P","edits":[]}"#)).hasPrefix("Error:"))
        #expect((await call(service, #"{"path":"none.json","project":"P","edits":[{"op":"delete","at":["a"]}]}"#)).hasPrefix("Error:"))
        try "{}".write(to: dir.appendingPathComponent("a.json"), atomically: true, encoding: .utf8)
        #expect((await call(service, #"{"path":"a.json","project":"P"}"#)).contains("'edits' is required"))
    }

    @Test("replaceData refuses to overwrite a file that changed after it was read")
    func raceGuard() async throws {
        let (_, dir) = try rig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.json")
        try "{\"a\":1}".write(to: url, atomically: true, encoding: .utf8)
        let manager = FileSystemManager(workspaces: [(name: "P", url: dir)])

        try "{\"a\":1,\"other\":true}".write(to: url, atomically: true, encoding: .utf8)
        await #expect(throws: ChappieError.self) {
            try await manager.replaceData(at: "a.json", projectName: "P", original: Data("{\"a\":1}".utf8), with: Data("{\"a\":2}".utf8))
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{\"a\":1,\"other\":true}")
    }

    @Test("Permissions survive and a symbolic link stays a link")
    func permissionsAndLink() async throws {
        let (_, dir) = try rig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.json")
        let link = dir.appendingPathComponent("link.json")
        try "{\"a\":1}".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: real.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let manager = FileSystemManager(workspaces: [(name: "P", url: dir)])

        try await manager.replaceData(at: "link.json", projectName: "P", original: Data("{\"a\":1}".utf8), with: Data("{\"a\":2}".utf8))
        #expect(try String(contentsOf: real, encoding: .utf8) == "{\"a\":2}")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
        let mode = try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int
        #expect(mode == 0o640)
    }
}
