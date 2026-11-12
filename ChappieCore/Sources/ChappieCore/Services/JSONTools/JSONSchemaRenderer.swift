// JSONSchemaRenderer.swift
// ChappieCore
//
// Turns a JSONShape into the text of json_schema, and runs the whole tool.

import Foundation

enum JSONSchemaTool {

    static func report(
        _ doc: JSONDocument, fileName: String, at: [JSONPathSegment], depth: Int, maxChars: Int
    ) throws -> String {
        let targets = doc.resolve(at)
        guard !targets.isEmpty else { throw JSONFragment.missingPath(doc, at) }
        let shape = JSONSchemaBuilder.build(doc, nodes: targets, maxLevels: depth)

        var lines: [String] = []
        let place = at.isEmpty ? "the whole file" : JSONPathSegment.render(at)
        let merged = targets.count > 1 ? ", merged from \(JSONText.count(targets.count)) matching places" : ""
        lines.append("Shape of \(fileName) — \(place)\(merged). No data, only structure; `e.g. at [...]` is where to look with json_get.")
        lines.append("")
        lines.append(headline(doc, shape))
        Renderer(doc: doc).nested(of: shape, indent: 1, into: &lines)
        lines.append("")
        lines.append("Next: json_get with an `at` path to see real content, json_find to search or to find what is missing.")
        return JSONOutput.fit(lines.joined(separator: "\n"), maxChars: maxChars, hint: "Use `at` to look at one part, or lower `depth`.")
    }

    // MARK: Headline

    /// One line that says what kinds a value has and the facts that matter for each.
    static func headline(_ doc: JSONDocument, _ shape: JSONShape) -> String {
        let kinds = shape.kindCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
        let parts = kinds.map { piece($0.key, shape) }
        var text = parts.joined(separator: " | ")
        if shape.kindCounts.count > 1 {
            let rare = kinds.dropFirst().compactMap { entry -> String? in
                guard let index = shape.firstOfKind[entry.key] else { return nil }
                return "\(entry.key.rawValue) \(JSONText.count(entry.value))× e.g. at \(JSONText.renderedPath(doc, index, limit: 120))"
            }
            text += "   [\(rare.joined(separator: "; "))]"
        }
        if shape.cutBelow { text += "   (deeper levels not shown: raise `depth` or use `at`)" }
        return text
    }

    private static func piece(_ kind: JSONKind, _ shape: JSONShape) -> String {
        switch kind {
        case .object:
            return shape.isDictionary ? "dictionary, \(JSONText.plural(shape.dictEntries, "entry", "entries"))" : "object"
        case .array:
            let length = shape.minLength == shape.maxLength ? "\(shape.maxLength)" : "\(shape.minLength)..\(shape.maxLength)"
            return "array, length \(length)"
        case .string:
            if !shape.distinctOverflow, shape.distinctStrings.count > 0, shape.stringCount >= 3 || shape.distinctStrings.count == 1 {
                let values = shape.distinctStrings.map(JSONText.quote).joined(separator: ", ")
                return shape.distinctStrings.count == 1 && shape.stringCount > 1 ? "string, always \(values)" : "string, one of \(values)"
            }
            let sample = shape.firstString.map { " e.g. \(JSONText.quote(JSONText.shorten($0, limit: 40)))" } ?? ""
            return "string\(sample)"
        case .number:
            let type = shape.allIntegers ? "integer" : "number"
            guard shape.minNumber.isFinite, shape.minNumber != shape.maxNumber else { return type }
            return "\(type) \(format(shape.minNumber))..\(format(shape.maxNumber))"
        case .bool:
            return "boolean"
        case .null:
            return "null"
        }
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    // MARK: Nested structure

    struct Renderer {
        let doc: JSONDocument
        static let maxProps = 60

        func nested(of shape: JSONShape, indent: Int, into lines: inout [String]) {
            let pad = String(repeating: "  ", count: indent)

            if shape.kindCounts[.object] != nil {
                if shape.isDictionary, let value = shape.dictValue {
                    let keys = shape.dictKeySample.map(JSONText.quote).joined(separator: ", ")
                    lines.append("\(pad)keys, e.g.: \(keys)")
                    lines.append("\(pad)every value: \(JSONSchemaTool.headline(doc, value))")
                    nested(of: value, indent: indent + 1, into: &lines)
                } else {
                    props(of: shape, pad: pad, indent: indent, into: &lines)
                }
            }
            if shape.kindCounts[.array] != nil, let item = shape.item {
                lines.append("\(pad)each item: \(JSONSchemaTool.headline(doc, item))")
                nested(of: item, indent: indent + 1, into: &lines)
            }
        }

        private func props(of shape: JSONShape, pad: String, indent: Int, into lines: inout [String]) {
            for entry in shape.props.prefix(Self.maxProps) {
                var line = "\(pad)\(JSONText.quote(entry.key)): \(JSONSchemaTool.headline(doc, entry.shape))"
                if entry.presence < shape.objectCount {
                    line += "   — optional, in \(JSONText.count(entry.presence)) of \(JSONText.count(shape.objectCount))"
                    if let first = entry.shape.firstOfKind.values.min() {
                        line += ", first at \(JSONText.renderedPath(doc, first, limit: 120))"
                    }
                }
                lines.append(line)
                nested(of: entry.shape, indent: indent + 1, into: &lines)
            }
            if shape.props.count > Self.maxProps {
                lines.append("\(pad)… and \(JSONText.count(shape.props.count - Self.maxProps)) more fields")
            }
        }
    }
}
