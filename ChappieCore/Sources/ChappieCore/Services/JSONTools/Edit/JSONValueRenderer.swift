// JSONValueRenderer.swift
// ChappieCore
//
// Writes a JSON value the way THE FILE writes its own values: indent unit, separator after a key,
// line endings, escaping of "/" and of non-ASCII characters, how empty containers look, and whether
// objects and arrays are split over lines. Only new fragments pass through here; the rest of the
// file is never rewritten.

import Foundation

struct JSONValueRenderer {

    let style: JSONStyle

    var unit: String { style.indentUnit ?? "  " }
    var lineEnding: String { style.lineEnding }

    /// Objects and arrays are split over lines when most of the file's containers are.
    func isMultiline(object: Bool) -> Bool {
        guard !style.isMinified else { return false }
        return object ? style.multilineObjects >= style.inlineObjects : style.multilineArrays >= style.inlineArrays
    }

    // MARK: Strings

    /// A string literal escaped like the file escapes: "\/" only when the file does, \uXXXX only when it does.
    func quote(_ text: String) -> String {
        var out = "\""
        out.reserveCapacity(text.utf8.count + 2)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "/": out += style.slashEscaping == .escaped ? "\\/" : "/"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else if scalar.value >= 0x80 && style.escapesNonASCII {
                    out += escapeUnicode(scalar)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private func escapeUnicode(_ scalar: Unicode.Scalar) -> String {
        if scalar.value <= 0xFFFF { return String(format: "\\u%04x", scalar.value) }
        let offset = scalar.value - 0x10000
        return String(format: "\\u%04x\\u%04x", 0xD800 + (offset >> 10), 0xDC00 + (offset & 0x3FF))
    }

    // MARK: Values

    /// `baseIndent` is the indentation of the line the value starts on; inner lines go one unit deeper.
    /// `inline` forces everything on one line: used inside a container the file keeps on one line.
    func render(_ doc: JSONDocument, _ index: Int, baseIndent: String, inline: Bool = false) -> String {
        switch doc.nodes[index].kind {
        case .string: return quote(doc.stringValue(of: index) ?? "")
        case .number, .bool, .null: return doc.rawText(of: index)
        case .object, .array: return container(doc, index, baseIndent: baseIndent, inline: inline)
        }
    }

    private func container(_ doc: JSONDocument, _ index: Int, baseIndent: String, inline: Bool) -> String {
        let node = doc.nodes[index]
        let isObject = node.kind == .object
        let open = isObject ? "{" : "[", close = isObject ? "}" : "]"
        guard !node.children.isEmpty else { return emptyContainer(isObject: isObject, baseIndent: baseIndent) }

        let multiline = !inline && isMultiline(object: isObject)
        let inner = baseIndent + unit
        let parts = node.children.map { child -> String in
            let key = isObject ? quote(doc.nodes[child].key ?? "") + style.keySeparator : ""
            return key + render(doc, child, baseIndent: multiline ? inner : baseIndent, inline: !multiline)
        }
        if multiline {
            return open + lineEnding + inner + parts.joined(separator: "," + lineEnding + inner) + lineEnding + baseIndent + close
        }
        return open + parts.joined(separator: style.isMinified ? "," : ", ") + close
    }

    /// An empty container written the way the file writes its own.
    func emptyContainer(isObject: Bool, baseIndent: String) -> String {
        let open = isObject ? "{" : "[", close = isObject ? "}" : "]"
        let form = isObject ? style.emptyObjectForm : style.emptyArrayForm
        // Xcode writes an empty object as "{", an empty line, then the closing brace at the member's indent.
        if form.contains("\n") { return open + lineEnding + lineEnding + baseIndent + close }
        return form
    }
}

// MARK: - Equality of two values

enum JSONValueEquality {

    /// Same value, ignoring formatting and the order of keys. Iterative: values can be deep.
    static func equal(_ a: JSONDocument, _ first: Int, _ b: JSONDocument, _ second: Int) -> Bool {
        var stack = [(first, second)]
        while let (x, y) = stack.popLast() {
            let left = a.nodes[x], right = b.nodes[y]
            guard left.kind == right.kind else { return false }
            switch left.kind {
            case .string:
                if a.stringValue(of: x) != b.stringValue(of: y) { return false }
            case .number:
                let lhs = a.rawText(of: x), rhs = b.rawText(of: y)
                if lhs != rhs {
                    guard let dl = Double(lhs), let dr = Double(rhs), dl == dr else { return false }
                }
            case .bool, .null:
                if a.rawText(of: x) != b.rawText(of: y) { return false }
            case .array:
                guard left.children.count == right.children.count else { return false }
                for pair in zip(left.children, right.children) { stack.append(pair) }
            case .object:
                guard left.children.count == right.children.count else { return false }
                for child in left.children {
                    guard let key = a.nodes[child].key, let other = b.member(key, of: y) else { return false }
                    stack.append((child, other))
                }
            }
        }
        return true
    }
}
