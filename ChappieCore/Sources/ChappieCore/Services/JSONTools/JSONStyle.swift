// JSONStyle.swift
// ChappieCore
//
// Detects how a JSON file is written, so new fragments can copy their neighbours
// and json_info can describe the file to the model in a few lines.

import Foundation

public struct JSONStyle: Sendable, Equatable {

    public enum KeyOrder: String, Sendable, Equatable {
        case sorted           // every object with 3+ members is in ascending byte order
        case sortedIgnoringCase
        case unsorted         // no object with 3+ members is sorted
        case mixed            // some are, some are not
        case notApplicable    // no object has enough members to tell
    }

    public enum SlashEscaping: String, Sendable, Equatable {
        case escaped, plain, mixed, none
    }

    /// One indentation step, e.g. "  ", "    " or "\t". Nil when no container is split over lines.
    public var indentUnit: String?
    /// Exactly what sits between a key and its value, colon included: ": ", " : " or ":".
    public var keySeparator: String
    /// "\n" or "\r\n".
    public var lineEnding: String
    public var endsWithNewline: Bool
    public var hasBOM: Bool
    public var hasComments: Bool
    public var hasTrailingCommas: Bool
    public var hasDuplicateKeys: Bool
    public var slashEscaping: SlashEscaping
    /// True when non-ASCII characters are written as \uXXXX rather than as themselves.
    public var escapesNonASCII: Bool
    public var keyOrder: KeyOrder
    public var multilineObjects: Int
    public var inlineObjects: Int
    public var multilineArrays: Int
    public var inlineArrays: Int
    public var emptyObjectForm: String
    public var emptyArrayForm: String

    /// "minified" when nothing is split over lines, otherwise "indented".
    public var isMinified: Bool { indentUnit == nil && multilineObjects + multilineArrays == 0 }

    public func indent(depth: Int) -> String {
        String(repeating: indentUnit ?? "", count: max(0, depth))
    }
}

// MARK: - Detection

extension JSONStyle {

    public static func detect(_ doc: JSONDocument) -> JSONStyle {
        var indentVotes: [String: Int] = [:]
        var deeperVotes: [String: Int] = [:]
        var separatorVotes: [String: Int] = [:]
        var multilineObjects = 0, inlineObjects = 0, multilineArrays = 0, inlineArrays = 0

        for (index, node) in doc.nodes.enumerated() {
            if node.kind == .object || node.kind == .array, let firstChild = node.children.first {
                let first = doc.nodes[firstChild]
                let gap = doc.bytes[(node.start + 1)..<first.memberStart]
                let multiline = gap.contains(0x0A)
                switch (node.kind, multiline) {
                case (.object, true): multilineObjects += 1
                case (.object, false): inlineObjects += 1
                case (_, true): multilineArrays += 1
                default: inlineArrays += 1
                }
            }
            if node.key != nil {
                let separator = String(decoding: doc.bytes[node.keyEnd..<node.start], as: UTF8.self)
                separatorVotes[separator, default: 0] += 1
            }
            guard index > 0, let leading = leadingIndent(of: node, in: doc) else { continue }
            if node.depth == 1 {
                indentVotes[leading, default: 0] += 1
            } else if node.depth == 2 {
                deeperVotes[leading, default: 0] += 1
            }
        }

        let indentUnit = mostCommon(indentVotes) ?? halve(mostCommon(deeperVotes))
        let separator = mostCommon(separatorVotes) ?? ": "
        let (order, _) = detectKeyOrder(doc)

        return JSONStyle(
            indentUnit: indentUnit,
            keySeparator: separator,
            lineEnding: detectLineEnding(doc.bytes),
            endsWithNewline: doc.bytes.last == 0x0A,
            hasBOM: doc.bomLength > 0,
            hasComments: doc.facts.hasComments,
            hasTrailingCommas: doc.facts.hasTrailingCommas,
            hasDuplicateKeys: doc.facts.hasDuplicateKeys,
            slashEscaping: slashEscaping(doc.facts),
            escapesNonASCII: doc.facts.hasUnicodeEscapes && !doc.facts.hasRawNonASCII,
            keyOrder: order,
            multilineObjects: multilineObjects,
            inlineObjects: inlineObjects,
            multilineArrays: multilineArrays,
            inlineArrays: inlineArrays,
            emptyObjectForm: emptyForm(doc.facts.emptyObjects, open: "{", close: "}"),
            emptyArrayForm: emptyForm(doc.facts.emptyArrays, open: "[", close: "]")
        )
    }

    /// Whitespace between the previous newline and the node, nil when something else shares that line.
    private static func leadingIndent(of node: JSONNode, in doc: JSONDocument) -> String? {
        var cursor = node.memberStart
        while cursor > 0, doc.bytes[cursor - 1] == 0x20 || doc.bytes[cursor - 1] == 0x09 { cursor -= 1 }
        guard cursor > 0, doc.bytes[cursor - 1] == 0x0A else { return nil }
        return String(decoding: doc.bytes[cursor..<node.memberStart], as: UTF8.self)
    }

    /// A unit guessed from depth-2 lines when no depth-1 line is indented: half of the indent.
    private static func halve(_ value: String?) -> String? {
        guard let value, value.count >= 2, value.count % 2 == 0 else { return nil }
        return String(value.prefix(value.count / 2))
    }

    private static func mostCommon(_ votes: [String: Int]) -> String? {
        votes.max { left, right in
            left.value != right.value ? left.value < right.value : left.key > right.key
        }?.key
    }

    private static func detectLineEnding(_ bytes: [UInt8]) -> String {
        var crlf = 0, lf = 0
        for (index, byte) in bytes.enumerated() where byte == 0x0A {
            if index > 0, bytes[index - 1] == 0x0D { crlf += 1 } else { lf += 1 }
        }
        return crlf > lf ? "\r\n" : "\n"
    }

    private static func slashEscaping(_ facts: JSONLexicalFacts) -> SlashEscaping {
        switch (facts.hasEscapedSlash, facts.hasPlainSlash) {
        case (true, true): return .mixed
        case (true, false): return .escaped
        case (false, true): return .plain
        default: return .none
        }
    }

    /// Chooses the most frequent way empty containers are written.
    private static func emptyForm(_ counts: JSONEmptyFormCounts, open: String, close: String) -> String {
        if counts.multiline > counts.compact, counts.multiline > counts.spaced { return "\(open)\n\n\(close)" }
        if counts.spaced > counts.compact { return "\(open) \(close)" }
        return "\(open)\(close)"
    }

    // MARK: Key order

    /// How members are ordered across the whole file, and how many objects were judged.
    public static func detectKeyOrder(_ doc: JSONDocument) -> (KeyOrder, Int) {
        var sorted = 0, caseInsensitive = 0, unsorted = 0
        for node in doc.nodes where node.kind == .object && node.children.count >= 3 {
            let keys = node.children.compactMap { doc.nodes[$0].key }
            if isAscending(keys, by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                sorted += 1
            } else if isAscending(keys, by: { $0.lowercased().utf8.lexicographicallyPrecedes($1.lowercased().utf8) }) {
                caseInsensitive += 1
            } else {
                unsorted += 1
            }
        }
        let judged = sorted + caseInsensitive + unsorted
        if judged == 0 { return (.notApplicable, 0) }
        if unsorted == 0 { return (caseInsensitive == 0 ? .sorted : .sortedIgnoringCase, judged) }
        if sorted + caseInsensitive == 0 { return (.unsorted, judged) }
        return (.mixed, judged)
    }

    /// Ascending order, equal neighbours allowed (duplicates are legal JSON).
    static func isAscending(_ keys: [String], by less: (String, String) -> Bool) -> Bool {
        guard keys.count > 1 else { return true }
        for index in 1..<keys.count where less(keys[index], keys[index - 1]) { return false }
        return true
    }

    /// Whether the members of one object are in ascending byte order.
    public static func isSorted(object index: Int, in doc: JSONDocument, ignoringCase: Bool = false) -> Bool {
        let keys = doc.nodes[index].children.compactMap { doc.nodes[$0].key }
        if ignoringCase {
            return isAscending(keys) { $0.lowercased().utf8.lexicographicallyPrecedes($1.lowercased().utf8) }
        }
        return isAscending(keys) { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
}
