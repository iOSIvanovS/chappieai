// JSONText.swift
// ChappieCore
//
// Small text helpers shared by json_info / json_schema / json_get / json_find, and the one place
// where every json_* answer is held to its size limit.

import Foundation

enum JSONText {

    /// A JSON string literal. Non-ASCII stays as is and "/" is not escaped: the text is read by a model.
    static func quote(_ text: String) -> String {
        var out = "\""
        out.reserveCapacity(text.utf8.count + 2)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    /// At most `limit` characters; the rest is replaced by a note that says how much was dropped.
    static func shorten(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…(+\(text.count - limit) chars)"
    }

    /// 12345 -> "12,345".
    static func count(_ value: Int) -> String {
        let digits = Array(String(abs(value)))
        var out = ""
        for (offset, digit) in digits.enumerated() {
            if offset > 0, (digits.count - offset) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return value < 0 ? "-" + out : out
    }

    static func size(_ bytes: Int) -> String {
        let kb = 1024.0, mb = kb * 1024
        let value = Double(bytes)
        if value < kb { return "\(bytes) B" }
        if value < mb { return String(format: "%.1f KB", value / kb) }
        return String(format: "%.1f MB", value / mb)
    }

    static func plural(_ number: Int, _ one: String, _ many: String) -> String {
        "\(count(number)) \(number == 1 ? one : many)"
    }

    /// "object, 472 keys", "array, 3 items", "string", "number" …
    static func summary(_ doc: JSONDocument, _ index: Int) -> String {
        let node = doc.nodes[index]
        switch node.kind {
        case .object: return "object, " + plural(node.children.count, "key", "keys")
        case .array: return "array, " + plural(node.children.count, "item", "items")
        default: return node.kind.rawValue
        }
    }

    /// "L12" or "L12-L40": the lines the member (key included) occupies.
    static func lineSpan(_ doc: JSONDocument, _ index: Int) -> String {
        let node = doc.nodes[index]
        let first = doc.lineNumber(at: node.memberStart)
        let last = doc.lineNumber(at: max(node.memberStart, node.end - 1))
        return first == last ? "L\(first)" : "L\(first)-L\(last)"
    }

    /// The path of a node as a JSON array, shortened when it is very long.
    static func renderedPath(_ doc: JSONDocument, _ index: Int, limit: Int = 160) -> String {
        shorten(JSONPathSegment.render(doc.path(of: index)), limit: limit)
    }

    /// A scalar's source text, a long string cut so one value cannot flood the answer.
    static func scalarPreview(_ doc: JSONDocument, _ index: Int, limit: Int = 100) -> String {
        shorten(doc.rawText(of: index), limit: limit)
    }
}

// MARK: - Output size

enum JSONOutput {
    static let defaultChars = 8_000
    static let minChars = 1_000
    static let maxChars = 40_000

    static func clampChars(_ requested: Int?) -> Int {
        min(maxChars, max(minChars, requested ?? defaultChars))
    }

    /// Returns `text` as is when it fits, otherwise whole lines up to the limit plus a note.
    static func fit(_ text: String, maxChars limit: Int, hint: String) -> String {
        guard text.utf8.count > limit else { return text }
        var kept: [Substring] = []
        var used = 0
        var droppedLines = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let cost = line.utf8.count + 1
            if droppedLines == 0, used + cost <= limit {
                kept.append(line)
                used += cost
            } else {
                droppedLines += 1
            }
        }
        return kept.joined(separator: "\n")
            + "\n… cut here: \(JSONText.count(droppedLines)) more lines did not fit into \(JSONText.count(limit)) characters. \(hint)"
    }
}

// MARK: - Arguments

/// Typed access to the flat string map every tool executor receives.
struct JSONToolArgs {
    let values: [String: String]

    func string(_ name: String) -> String? {
        guard let value = values[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws -> Int {
        guard let text = string(name) else { return fallback }
        guard let number = Int(text) ?? Double(text).map({ Int($0) }) else {
            throw JSONToolError("Argument '\(name)' must be a whole number, got '\(text)'.")
        }
        return min(range.upperBound, max(range.lowerBound, number))
    }

    func bool(_ name: String, default fallback: Bool = false) -> Bool {
        guard let text = string(name)?.lowercased() else { return fallback }
        return text == "true" || text == "1" || text == "yes"
    }

    /// A path argument; missing means `fallback` (the root by default).
    func path(_ name: String, default fallback: [JSONPathSegment] = []) throws -> [JSONPathSegment] {
        guard let text = string(name) else { return fallback }
        return try JSONPathSegment.parseList(text, argument: name)
    }

    var maxChars: Int { JSONOutput.clampChars(string("max_chars").flatMap { Int($0) }) }
}
