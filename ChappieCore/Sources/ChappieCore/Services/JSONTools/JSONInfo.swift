// JSONInfo.swift
// ChappieCore
//
// json_info: facts about a JSON file in a few hundred tokens, whatever its size.
// Answers "what am I dealing with" and shows where the big parts are, without any data.

import Foundation

enum JSONInfo {

    static func report(_ doc: JSONDocument, fileName: String, maxChars: Int) -> String {
        let style = JSONStyle.detect(doc)
        let root = doc.rootNode
        var lines: [String] = []

        lines.append("\(fileName): \(JSONText.size(doc.bytes.count)), \(JSONText.plural(doc.lineCount, "line", "lines")), UTF-8\(style.hasBOM ? " with BOM" : "")")
        lines.append("Root: \(JSONText.summary(doc, doc.root)). Deepest nesting: \(doc.nodes.map(\.depth).max() ?? 0) levels. Values in total: \(JSONText.count(doc.nodes.count)).")
        lines.append("")
        lines.append("Content by type: " + kindCounts(doc))
        lines.append(contentsOf: overview(doc, root: root))
        lines.append("")
        lines.append("Style (new fragments must copy it; json_edit does this automatically):")
        lines.append(contentsOf: styleLines(style))

        let problems = warnings(style)
        if !problems.isEmpty {
            lines.append("")
            lines.append("Notes:")
            lines.append(contentsOf: problems.map { "- \($0)" })
        }
        lines.append("")
        lines.append("Next: json_schema for the shape, json_get for a fragment (path = JSON array like \(JSONPathSegment.example)), json_find to search by structure.")
        return JSONOutput.fit(lines.joined(separator: "\n"), maxChars: maxChars, hint: "Raise max_chars to see the rest.")
    }

    // MARK: Parts

    private static func kindCounts(_ doc: JSONDocument) -> String {
        var counts: [JSONKind: Int] = [:]
        for node in doc.nodes { counts[node.kind, default: 0] += 1 }
        let order: [JSONKind] = [.object, .array, .string, .number, .bool, .null]
        return order.compactMap { kind in counts[kind].map { "\(JSONText.count($0)) \(kind.rawValue)" } }.joined(separator: ", ")
    }

    /// Top-level members (or the biggest containers when the root has too many).
    private static func overview(_ doc: JSONDocument, root: JSONNode) -> [String] {
        guard root.kind == .object || root.kind == .array else { return [] }
        var lines = ["", root.kind == .object ? "Top-level keys:" : "Top-level items (first 12):"]
        let shown = root.children.prefix(root.kind == .object ? 25 : 12)
        for child in shown {
            let node = doc.nodes[child]
            let label = node.key.map(JSONText.quote) ?? "[\(root.children.firstIndex(of: child) ?? 0)]"
            lines.append("  \(label): \(JSONText.summary(doc, child)) (\(JSONText.lineSpan(doc, child)))")
        }
        if root.children.count > shown.count {
            lines.append("  … and \(JSONText.count(root.children.count - shown.count)) more")
        }

        let big = biggestContainers(doc)
        if !big.isEmpty {
            lines.append("")
            lines.append("Largest containers:")
            for index in big {
                lines.append("  \(JSONText.renderedPath(doc, index, limit: 100)): \(JSONText.summary(doc, index))")
            }
        }
        return lines
    }

    private static func biggestContainers(_ doc: JSONDocument) -> [Int] {
        let candidates = doc.nodes.indices.filter {
            ($0 > 0) && (doc.nodes[$0].kind == .object || doc.nodes[$0].kind == .array) && doc.nodes[$0].children.count >= 50
        }
        return Array(candidates.sorted { doc.nodes[$0].children.count > doc.nodes[$1].children.count }.prefix(5))
    }

    private static func styleLines(_ style: JSONStyle) -> [String] {
        var lines: [String] = []
        if style.isMinified {
            lines.append("- layout: minified, everything on one line")
        } else {
            let unit = style.indentUnit.map(describeIndent) ?? "no regular indent"
            lines.append("- indent: \(unit); \(style.multilineObjects) objects and \(style.multilineArrays) arrays are split over lines, \(style.inlineObjects) objects and \(style.inlineArrays) arrays stay on one line")
        }
        lines.append("- between key and value: \(JSONText.quote(style.keySeparator))")
        lines.append("- line ending: \(style.lineEnding == "\r\n" ? "CRLF" : "LF"), \(style.endsWithNewline ? "file ends with a newline" : "no newline at the end of the file")")
        lines.append("- slash in strings: \(slashText(style.slashEscaping))")
        lines.append("- non-ASCII characters: \(style.escapesNonASCII ? "written as \\uXXXX" : "written as they are")")
        lines.append("- key order: \(orderText(style.keyOrder))")
        lines.append("- empty object: \(JSONText.quote(style.emptyObjectForm)), empty array: \(JSONText.quote(style.emptyArrayForm))")
        return lines
    }

    private static func warnings(_ style: JSONStyle) -> [String] {
        var notes: [String] = []
        if style.hasComments { notes.append("the file has comments (JSONC); they are kept as they are") }
        if style.hasTrailingCommas { notes.append("the file has trailing commas (JSONC)") }
        if style.hasDuplicateKeys { notes.append("some object has the same key twice; paths use the first one") }
        return notes
    }

    private static func describeIndent(_ unit: String) -> String {
        if unit.allSatisfy({ $0 == "\t" }) { return unit.count == 1 ? "one tab" : "\(unit.count) tabs" }
        if unit.allSatisfy({ $0 == " " }) { return "\(unit.count) spaces" }
        return JSONText.quote(unit)
    }

    private static func slashText(_ value: JSONStyle.SlashEscaping) -> String {
        switch value {
        case .escaped: return "written as \\/"
        case .plain: return "written as /"
        case .mixed: return "both \\/ and / occur"
        case .none: return "no slashes in the file"
        }
    }

    private static func orderText(_ value: JSONStyle.KeyOrder) -> String {
        switch value {
        case .sorted: return "alphabetical in every object"
        case .sortedIgnoringCase: return "alphabetical, ignoring case"
        case .unsorted: return "not sorted (insertion order)"
        case .mixed: return "some objects are sorted, some are not"
        case .notApplicable: return "no object with 3+ keys, cannot tell"
        }
    }
}
