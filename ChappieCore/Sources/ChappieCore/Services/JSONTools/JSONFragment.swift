// JSONFragment.swift
// ChappieCore
//
// json_get: one part of a JSON file, in a form that fits the size limit.
//   1. If the lines the value occupies fit: they are returned exactly as in the file, with line numbers.
//      This is the "show me 100 lines so I can see the style" use.
//   2. Otherwise a collapsed view: containers deeper than a depth that FITS are replaced by
//      `{… 472 keys}` with the lines they occupy, so the model can ask for them one by one.

import Foundation

enum JSONFragment {

    // MARK: Entry

    static func get(
        _ doc: JSONDocument, fileName: String, at: [JSONPathSegment], depth: Int?, maxChars: Int
    ) throws -> String {
        let targets = doc.resolve(at)
        guard !targets.isEmpty else { throw missingPath(doc, at) }
        if targets.count > 1 {
            return many(doc, fileName: fileName, at: at, targets: targets, maxChars: maxChars)
        }
        return one(doc, fileName: fileName, index: targets[0], depth: depth, maxChars: maxChars)
    }

    // MARK: One value

    private static func one(_ doc: JSONDocument, fileName: String, index: Int, depth: Int?, maxChars: Int) -> String {
        let node = doc.nodes[index]
        let place = index == doc.root ? "the whole file" : JSONText.renderedPath(doc, index)
        let header = "\(fileName) — \(place): \(JSONText.summary(doc, index)), \(JSONText.lineSpan(doc, index))"

        if depth == nil, let raw = rawLines(doc, index: index, maxChars: maxChars) {
            return "\(header)\n\(raw)"
        }
        if node.kind != .object && node.kind != .array {
            return "\(header)\n\(JSONText.shorten(doc.rawText(of: index), limit: maxChars))"
        }

        let (text, usedDepth, collapsed) = collapsedView(doc, index: index, depth: depth, maxChars: maxChars)
        var out = "\(header)\nCollapsed view (depth \(usedDepth)); numbers after // are the lines in the file.\n\(text)"
        if collapsed {
            out += "\nTo open a collapsed part: json_get with `at` = its path, or raise `depth`/`max_chars`."
        }
        return out
    }

    /// The file's own lines for this value, numbered; nil when they do not fit.
    private static func rawLines(_ doc: JSONDocument, index: Int, maxChars: Int) -> String? {
        let node = doc.nodes[index]
        let first = doc.lineNumber(at: node.memberStart)
        let last = doc.lineNumber(at: max(node.memberStart, node.end - 1))
        let from = doc.lineStarts[first - 1]
        let to = last < doc.lineStarts.count ? doc.lineStarts[last] : doc.bytes.count
        guard to - from <= maxChars else { return nil }

        let width = String(last).count
        var out: [String] = []
        for number in first...last {
            let start = doc.lineStarts[number - 1]
            var end = number < doc.lineStarts.count ? doc.lineStarts[number] : doc.bytes.count
            while end > start, doc.bytes[end - 1] == 0x0A || doc.bytes[end - 1] == 0x0D { end -= 1 }
            let text = String(decoding: doc.bytes[start..<end], as: UTF8.self)
            out.append(String(repeating: " ", count: width - String(number).count) + "\(number)| \(text)")
        }
        return out.joined(separator: "\n")
    }

    // MARK: Collapsed view

    /// Renders with the largest depth that fits; returns the text, the depth used and whether anything was collapsed.
    private static func collapsedView(
        _ doc: JSONDocument, index: Int, depth: Int?, maxChars: Int
    ) -> (String, Int, Bool) {
        if let depth {
            let view = render(doc, index: index, depth: depth)
            return (JSONOutput.fit(view.text, maxChars: maxChars, hint: "Lower `depth`."), depth, view.collapsed)
        }
        var best = render(doc, index: index, depth: 1)
        var bestDepth = 1
        var level = 2
        while best.collapsed, level <= 40 {
            let candidate = render(doc, index: index, depth: level)
            // Past a certain depth nothing new appears (the per-level member caps stop it): stop there.
            if candidate.text.utf8.count > maxChars || candidate.text == best.text { break }
            best = candidate
            bestDepth = level
            level += 1
        }
        return (JSONOutput.fit(best.text, maxChars: maxChars, hint: "Use `at` for one part."), bestDepth, best.collapsed)
    }

    private struct Rendered {
        var text: String
        var collapsed: Bool
    }

    /// How many members or items of one container are written out. The deeper the level, the fewer:
    /// the first few entries of a big map show its shape, the rest only costs the reader's attention.
    private static func membersShown(atLevel level: Int) -> Int {
        switch level {
        case 0: return 40
        case 1: return 12
        case 2: return 5
        default: return 3
        }
    }

    private static func render(_ doc: JSONDocument, index: Int, depth: Int) -> Rendered {
        var lines: [String] = []
        var collapsed = false
        // Explicit stack: depth can be large and tool code must not recurse on a small thread stack.
        enum Step { case node(Int, Int, String, String, Bool), close(String, String, Bool), more(String, Int, Int, Int) }
        var stack: [Step] = [.node(index, 0, "", "", false)]

        while let step = stack.popLast() {
            switch step {
            case .node(let current, let level, let pad, let label, let comma):
                let node = doc.nodes[current]
                let tail = comma ? "," : ""
                guard node.kind == .object || node.kind == .array else {
                    lines.append("\(pad)\(label)\(JSONText.scalarPreview(doc, current))\(tail)")
                    continue
                }
                let open = node.kind == .object ? "{" : "["
                let close = node.kind == .object ? "}" : "]"
                if node.children.isEmpty {
                    lines.append("\(pad)\(label)\(open)\(close)\(tail)")
                } else if level >= depth {
                    collapsed = true
                    lines.append("\(pad)\(label)\(open)… \(JSONText.summary(doc, current))\(close)\(tail)  // \(JSONText.lineSpan(doc, current))")
                } else {
                    lines.append("\(pad)\(label)\(open)")
                    stack.append(.close(pad, close, comma))
                    let shown = Array(node.children.prefix(membersShown(atLevel: level)))
                    let hidden = node.children.count - shown.count
                    if hidden > 0 {
                        collapsed = true
                        stack.append(.more(pad + "  ", hidden, node.children[shown.count], node.children[node.children.count - 1]))
                    }
                    for (position, child) in shown.enumerated().reversed() {
                        let key = doc.nodes[child].key.map { JSONText.quote($0) + ": " } ?? ""
                        stack.append(.node(child, level + 1, pad + "  ", key, position < shown.count - 1 || hidden > 0))
                    }
                }
            case .close(let pad, let close, let comma):
                lines.append("\(pad)\(close)\(comma ? "," : "")")
            case .more(let pad, let count, let first, let last):
                let from = doc.lineNumber(at: doc.nodes[first].memberStart)
                let to = doc.lineNumber(at: max(doc.nodes[last].memberStart, doc.nodes[last].end - 1))
                lines.append("\(pad)… \(JSONText.count(count)) more  // L\(from)-L\(to)")
            }
        }
        return Rendered(text: lines.joined(separator: "\n"), collapsed: collapsed)
    }

    // MARK: Several values

    private static func many(_ doc: JSONDocument, fileName: String, at: [JSONPathSegment], targets: [Int], maxChars: Int) -> String {
        var lines = ["\(fileName) — \(JSONPathSegment.render(at)) matches \(JSONText.count(targets.count)) values:"]
        for index in targets.prefix(60) {
            let node = doc.nodes[index]
            let summary = node.kind == .object || node.kind == .array
                ? JSONText.summary(doc, index)
                : JSONText.scalarPreview(doc, index, limit: 80)
            lines.append("  \(JSONText.renderedPath(doc, index, limit: 100)) = \(summary)  // \(JSONText.lineSpan(doc, index))")
        }
        if targets.count > 60 { lines.append("  … and \(JSONText.count(targets.count - 60)) more") }
        lines.append("A wildcard matched several places. Pass one concrete path to see its content, or use json_find to filter.")
        return JSONOutput.fit(lines.joined(separator: "\n"), maxChars: maxChars, hint: "Narrow the path.")
    }

    // MARK: Path that leads nowhere

    /// Explains where a path stops working and what is available there.
    static func missingPath(_ doc: JSONDocument, _ at: [JSONPathSegment]) -> JSONToolError {
        var resolved = at.count - 1
        var anchor = doc.resolve([])
        while resolved >= 0 {
            let found = doc.resolve(Array(at[0..<resolved]))
            if !found.isEmpty { anchor = found; break }
            resolved -= 1
        }
        let failedIndex = max(0, resolved)
        let failed = at.indices.contains(failedIndex) ? at[failedIndex] : nil
        let reached = failedIndex == 0 ? "the root" : JSONPathSegment.render(Array(at[0..<failedIndex]))

        var message = "Nothing at \(JSONPathSegment.render(at)). The path works up to \(reached); the segment "
        message += failed.map(describe) ?? "?"
        message += " is not there."

        guard let node = anchor.first else { return JSONToolError(message) }
        let target = doc.nodes[node]
        switch target.kind {
        case .object:
            let keys = target.children.compactMap { doc.nodes[$0].key }
            message += " That object has \(JSONText.plural(keys.count, "key", "keys")): "
            message += suggestions(for: failed, among: keys).map(JSONText.quote).joined(separator: ", ")
            if keys.count > 20 { message += ", …" }
        case .array:
            message += " That is an array of \(JSONText.plural(target.children.count, "item", "items")); use an integer position (0 first, -1 last) or \"*\"."
        default:
            message += " That value is a \(target.kind.rawValue), it has no members."
        }
        return JSONToolError(message)
    }

    private static func describe(_ segment: JSONPathSegment) -> String {
        switch segment {
        case .key(let key): return JSONText.quote(key)
        case .index(let position): return String(position)
        case .glob(let glob): return JSONText.quote(glob.source)
        case .anyDepth: return "\"**\""
        }
    }

    /// Up to 20 keys; those that look like the wanted one go first.
    private static func suggestions(for segment: JSONPathSegment?, among keys: [String]) -> [String] {
        guard case .key(let wanted)? = segment else { return Array(keys.prefix(20)) }
        let lowered = wanted.lowercased()
        let close = keys.filter { $0.lowercased().contains(lowered) || lowered.contains($0.lowercased()) }
        let rest = keys.filter { !close.contains($0) }
        return Array((close + rest).prefix(20))
    }
}
