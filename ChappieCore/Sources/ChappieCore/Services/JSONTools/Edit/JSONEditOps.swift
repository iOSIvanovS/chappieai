// JSONEditOps.swift
// ChappieCore
//
// The operations of json_edit and the reader that turns the `edits` argument into them.
// The argument is parsed with our own JSON parser, not JSONSerialization: a value the model sends
// keeps the order of its keys, which then becomes the order of keys written into the file.

import Foundation

/// A value taken from the `edits` text: the document it lives in and its node.
struct JSONEditValue {
    let doc: JSONDocument
    let node: Int
}

enum JSONEditPosition: Equatable {
    case auto, start, end, sorted
    case after(String)
    case before(String)
    case index(Int)
}

enum JSONEditAction {
    case set(JSONEditValue)
    case delete
    case insert(key: String?, value: JSONEditValue, position: JSONEditPosition)
    case rename(to: String)
}

struct JSONEditOp {
    /// 1-based position in the `edits` array, used in every message.
    let number: Int
    let action: JSONEditAction
    let at: [JSONPathSegment]
    let expect: JSONEditValue?

    var verb: String {
        switch action {
        case .set: return "set"
        case .delete: return "delete"
        case .insert: return "insert"
        case .rename: return "rename"
        }
    }

    var label: String { "edits[\(number)] \(verb) at \(JSONPathSegment.render(at))" }
}

// MARK: - Reader

enum JSONEditParser {

    static let maxOps = 2_000
    /// A value deeper than this is refused: the renderer recurses once per level.
    static let maxValueDepth = 64
    static let allowedFields: Set<String> = ["op", "at", "value", "expect", "key", "position", "to"]

    static let formatHint = #"Example: [{"op":"set","at":["strings","Cancel","comment"],"value":"Button title"}]"#

    /// Reads every operation; all problems are reported together.
    static func parse(_ text: String) throws -> [JSONEditOp] {
        let doc: JSONDocument
        do {
            doc = try JSONDocument.parse(text)
        } catch let error as JSONParseError {
            throw JSONToolError("Argument 'edits' is not valid JSON. \(error.errorDescription ?? error.message) \(formatHint)")
        }
        let entries: [Int]
        switch doc.rootNode.kind {
        case .array: entries = doc.rootNode.children
        case .object: entries = [doc.root]
        default: throw JSONToolError("Argument 'edits' must be a JSON array of operations. \(formatHint)")
        }
        guard !entries.isEmpty else { throw JSONToolError("Argument 'edits' is empty: give at least one operation. \(formatHint)") }
        guard entries.count <= maxOps else { throw JSONToolError("Argument 'edits' has \(entries.count) operations; the limit is \(maxOps) per call. Split it.") }

        var ops: [JSONEditOp] = []
        var problems: [String] = []
        for (offset, entry) in entries.enumerated() {
            do {
                ops.append(try parseOp(doc, entry, number: offset + 1))
            } catch let error as JSONToolError {
                problems.append(error.message)
            }
        }
        if !problems.isEmpty { throw JSONToolError(problems.joined(separator: "\n")) }
        return ops
    }

    // MARK: One operation

    private static func parseOp(_ doc: JSONDocument, _ index: Int, number: Int) throws -> JSONEditOp {
        let prefix = "edits[\(number)]"
        guard doc.nodes[index].kind == .object else {
            throw JSONToolError("\(prefix): must be an object like {\"op\":\"set\",\"at\":[...],\"value\":...}.")
        }
        var fields: [String: Int] = [:]
        for child in doc.nodes[index].children {
            if let key = doc.nodes[child].key, fields[key] == nil { fields[key] = child }
        }
        if let unknown = fields.keys.filter({ !allowedFields.contains($0) }).sorted().first {
            throw JSONToolError("\(prefix): unknown field '\(unknown)'. Allowed: \(allowedFields.sorted().joined(separator: ", ")).")
        }
        guard let opNode = fields["op"], let opName = doc.stringValue(of: opNode) else {
            throw JSONToolError("\(prefix): 'op' is required and must be \"set\", \"delete\", \"insert\" or \"rename\".")
        }
        guard let atNode = fields["at"] else {
            throw JSONToolError("\(prefix) (\(opName)): 'at' is required, a JSON array path such as [\"strings\",\"Cancel\"].")
        }
        let at = try path(doc, atNode, prefix: prefix)

        func forbid(_ names: [String]) throws {
            for name in names where fields[name] != nil {
                throw JSONToolError("\(prefix) (\(opName)): field '\(name)' does not apply to \(opName).")
            }
        }
        func required(_ name: String) throws -> JSONEditValue {
            guard let node = fields[name] else { throw JSONToolError("\(prefix) (\(opName)): '\(name)' is required.") }
            return try makeValue(doc, node, prefix: prefix, field: name)
        }

        let action: JSONEditAction
        switch opName {
        case "set":
            try forbid(["key", "position", "to"])
            action = .set(try required("value"))
        case "delete":
            try forbid(["value", "key", "position", "to"])
            action = .delete
        case "insert":
            try forbid(["to"])
            let key = try fields["key"].map { node -> String in
                guard let text = doc.stringValue(of: node) else { throw JSONToolError("\(prefix) (insert): 'key' must be a string.") }
                return text
            }
            let position = try fields["position"].map { try position(doc, $0, prefix: prefix) } ?? .auto
            action = .insert(key: key, value: try required("value"), position: position)
        case "rename":
            try forbid(["value", "key", "position"])
            guard let toNode = fields["to"], let newKey = doc.stringValue(of: toNode) else {
                throw JSONToolError("\(prefix) (rename): 'to' is required, the new key as a string.")
            }
            action = .rename(to: newKey)
        default:
            throw JSONToolError("\(prefix): unknown op '\(opName)'. Use set, delete, insert or rename.")
        }

        var expect: JSONEditValue?
        if let node = fields["expect"] {
            if case .insert = action { throw JSONToolError("\(prefix) (insert): 'expect' does not apply to insert, there is no current value.") }
            expect = try makeValue(doc, node, prefix: prefix, field: "expect")
        }
        return JSONEditOp(number: number, action: action, at: at, expect: expect)
    }

    // MARK: Fields

    private static func makeValue(_ doc: JSONDocument, _ node: Int, prefix: String, field: String) throws -> JSONEditValue {
        let base = doc.nodes[node].depth
        for index in node..<doc.subtreeEnd(of: node) where doc.nodes[index].depth - base > maxValueDepth {
            throw JSONToolError("\(prefix): '\(field)' is nested deeper than \(maxValueDepth) levels.")
        }
        return JSONEditValue(doc: doc, node: node)
    }

    private static func path(_ doc: JSONDocument, _ node: Int, prefix: String) throws -> [JSONPathSegment] {
        guard doc.nodes[node].kind == .array else {
            throw JSONToolError("\(prefix): 'at' must be a JSON array of segments, for example [\"strings\",\"Cancel\"].")
        }
        return try doc.nodes[node].children.map { child in
            switch doc.nodes[child].kind {
            case .string:
                return JSONPathSegment.make(doc.stringValue(of: child) ?? "")
            case .number:
                guard let value = Int(doc.rawText(of: child)) else {
                    throw JSONToolError("\(prefix): an array position in 'at' must be a whole number.")
                }
                return .index(value)
            default:
                throw JSONToolError("\(prefix): every segment of 'at' must be a string or an integer.")
            }
        }
    }

    private static func position(_ doc: JSONDocument, _ node: Int, prefix: String) throws -> JSONEditPosition {
        let bad = JSONToolError("""
        \(prefix) (insert): 'position' must be "auto", "start", "end", "sorted", {"after":"key"}, {"before":"key"} or an integer array position.
        """)
        switch doc.nodes[node].kind {
        case .string:
            switch doc.stringValue(of: node) {
            case "auto": return .auto
            case "start": return .start
            case "end": return .end
            case "sorted": return .sorted
            default: throw bad
            }
        case .number:
            guard let value = Int(doc.rawText(of: node)) else { throw bad }
            return .index(value)
        case .object:
            let children = doc.nodes[node].children
            guard children.count == 1, let anchor = doc.stringValue(of: children[0]) else { throw bad }
            switch doc.nodes[children[0]].key {
            case "after": return .after(anchor)
            case "before": return .before(anchor)
            default: throw bad
            }
        default:
            throw bad
        }
    }
}
