// JSONFinder.swift
// ChappieCore
//
// json_find: search a JSON file by STRUCTURE, including what is missing.
//
// `at` picks the SUBJECTS (default: every node). Conditions are tested on each subject and ALL of them
// must hold. Paths inside conditions are relative to the subject:
//   key        the subject's own key matches this glob
//   kind       the subject is object / array / string / number / bool / null
//   has        a relative path exists            missing   a relative path does not exist
//   value_at   which value the next conditions look at (default: the subject itself)
//   equals / not_equals / contains   compare that value (strings decoded, other scalars as written)
// Typical use: "which entries under strings.* have no localizations.ru" =
//   at ["strings","*"], missing ["localizations","ru"], output "keys".

import Foundation

struct JSONFindQuery {
    var at: [JSONPathSegment] = []
    var key: JSONGlob?
    var kind: JSONKind?
    var has: [JSONPathSegment]?
    var missing: [JSONPathSegment]?
    var valueAt: [JSONPathSegment] = []
    var equals: String?
    var notEquals: String?
    var contains: String?
    var ignoreCase = false
    var output = Output.paths
    var show: [JSONPathSegment]?
    var groupBy: [JSONPathSegment]?
    var limit = 50

    enum Output: String { case paths, keys, values, count }

    var hasValueCondition: Bool { equals != nil || notEquals != nil || contains != nil }
    var hasAnyCondition: Bool {
        key != nil || kind != nil || has != nil || missing != nil || hasValueCondition
    }

    init() {}

    init(_ args: JSONToolArgs) throws {
        at = try args.path("at")
        has = try args.string("has") == nil ? nil : args.path("has")
        missing = try args.string("missing") == nil ? nil : args.path("missing")
        valueAt = try args.path("value_at")
        show = try args.string("show") == nil ? nil : args.path("show")
        groupBy = try args.string("group_by") == nil ? nil : args.path("group_by")
        if let text = args.string("key") { key = JSONGlob.compile(text).glob }
        if let text = args.string("kind") {
            guard let parsed = JSONKind(rawValue: text.lowercased()) else {
                throw JSONToolError("Argument 'kind' must be one of: object, array, string, number, bool, null.")
            }
            kind = parsed
        }
        equals = args.string("equals")
        notEquals = args.string("not_equals")
        contains = args.string("contains")
        ignoreCase = args.bool("ignore_case")
        if let text = args.string("output") {
            guard let parsed = Output(rawValue: text.lowercased()) else {
                throw JSONToolError("Argument 'output' must be one of: paths, keys, values, count.")
            }
            output = parsed
        }
        limit = try args.int("limit", default: 50, in: 1...500)
    }
}

enum JSONFinder {

    static func run(_ doc: JSONDocument, fileName: String, query: JSONFindQuery, maxChars: Int) throws -> String {
        let subjects = doc.resolve(query.at)
        guard !subjects.isEmpty else {
            if query.at.isEmpty { throw JSONToolError("The file has no values to search.") }
            throw JSONFragment.missingPath(doc, query.at)
        }
        let matches = subjects.filter { passes(doc, $0, query) }

        let scope = query.at.isEmpty ? "the whole file" : JSONPathSegment.render(query.at)
        var lines = ["\(fileName) — searched \(JSONText.plural(subjects.count, "value", "values")) in \(scope): \(JSONText.count(matches.count)) match."]

        if let groupBy = query.groupBy {
            lines.append(contentsOf: grouped(doc, matches, by: groupBy, limit: query.limit))
        } else {
            switch query.output {
            case .count: break
            case .keys: lines.append(contentsOf: keys(doc, matches, limit: query.limit))
            case .paths: lines.append(contentsOf: paths(doc, matches, query: query))
            case .values: lines.append(contentsOf: values(doc, matches, query: query))
            }
        }
        if matches.isEmpty, !query.hasAnyCondition {
            lines.append("No condition was given, so every searched value matches. Add key, kind, has, missing, equals, not_equals or contains.")
        }
        return JSONOutput.fit(lines.joined(separator: "\n"), maxChars: maxChars, hint: "Lower `limit`, narrow `at`, or raise `max_chars`.")
    }

    // MARK: Conditions

    private static func passes(_ doc: JSONDocument, _ index: Int, _ query: JSONFindQuery) -> Bool {
        let node = doc.nodes[index]
        if let key = query.key {
            guard let own = node.key, key.matches(own) else { return false }
        }
        if let kind = query.kind, node.kind != kind { return false }
        if let has = query.has, doc.resolve(has, from: index).isEmpty { return false }
        if let missing = query.missing, !doc.resolve(missing, from: index).isEmpty { return false }
        guard query.hasValueCondition else { return true }

        let candidates = doc.resolve(query.valueAt, from: index).filter { isScalar(doc, $0) }
        if let equals = query.equals, !candidates.contains(where: { same(text(doc, $0), equals, query) }) { return false }
        if let notEquals = query.notEquals, candidates.contains(where: { same(text(doc, $0), notEquals, query) }) { return false }
        if let part = query.contains, !candidates.contains(where: { has(text(doc, $0), part, query) }) { return false }
        return true
    }

    private static func isScalar(_ doc: JSONDocument, _ index: Int) -> Bool {
        let kind = doc.nodes[index].kind
        return kind != .object && kind != .array
    }

    /// Strings decoded, every other scalar exactly as written (5, true, null).
    private static func text(_ doc: JSONDocument, _ index: Int) -> String {
        doc.stringValue(of: index) ?? doc.rawText(of: index)
    }

    private static func same(_ left: String, _ right: String, _ query: JSONFindQuery) -> Bool {
        query.ignoreCase ? left.lowercased() == right.lowercased() : left == right
    }

    private static func has(_ whole: String, _ part: String, _ query: JSONFindQuery) -> Bool {
        query.ignoreCase ? whole.lowercased().contains(part.lowercased()) : whole.contains(part)
    }

    // MARK: Output

    private static func paths(_ doc: JSONDocument, _ matches: [Int], query: JSONFindQuery) -> [String] {
        var lines: [String] = []
        for index in matches.prefix(query.limit) {
            var line = "  \(JSONText.renderedPath(doc, index))  // \(JSONText.lineSpan(doc, index))"
            if let show = query.show { line += showText(doc, index, show) }
            lines.append(line)
        }
        lines.append(contentsOf: more(matches.count, query.limit))
        return lines
    }

    private static func values(_ doc: JSONDocument, _ matches: [Int], query: JSONFindQuery) -> [String] {
        let valuePath = query.show ?? query.valueAt
        var lines: [String] = []
        for index in matches.prefix(query.limit) {
            let shown = doc.resolve(valuePath, from: index).prefix(3).map { target -> String in
                isScalar(doc, target) ? JSONText.scalarPreview(doc, target, limit: 100) : JSONText.summary(doc, target)
            }
            let rendered = shown.isEmpty ? "(nothing there)" : shown.joined(separator: ", ")
            lines.append("  \(JSONText.renderedPath(doc, index, limit: 100)) = \(rendered)")
        }
        lines.append(contentsOf: more(matches.count, query.limit))
        return lines
    }

    private static func keys(_ doc: JSONDocument, _ matches: [Int], limit: Int) -> [String] {
        let shown = matches.prefix(limit).map { index -> String in
            if let key = doc.nodes[index].key { return JSONText.quote(key) }
            if case .index(let position)? = doc.path(of: index).last { return String(position) }
            return "?"
        }
        var lines = shown.isEmpty ? [] : ["  [" + shown.joined(separator: ", ") + "]"]
        lines.append(contentsOf: more(matches.count, limit))
        return lines
    }

    private static func showText(_ doc: JSONDocument, _ index: Int, _ show: [JSONPathSegment]) -> String {
        let found = doc.resolve(show, from: index).prefix(3)
        if found.isEmpty { return "  → (nothing at \(JSONPathSegment.render(show)))" }
        let parts = found.map { isScalar(doc, $0) ? JSONText.scalarPreview(doc, $0, limit: 80) : JSONText.summary(doc, $0) }
        return "  → " + parts.joined(separator: ", ")
    }

    private static func more(_ total: Int, _ limit: Int) -> [String] {
        total > limit ? ["  … and \(JSONText.count(total - limit)) more (raise `limit` to see them)"] : []
    }

    private static func grouped(_ doc: JSONDocument, _ matches: [Int], by path: [JSONPathSegment], limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        var missing = 0
        for index in matches {
            let found = doc.resolve(path, from: index).first { isScalar(doc, $0) }
            guard let found else { missing += 1; continue }
            let label = JSONText.shorten(text(doc, found), limit: 60)
            if counts[label] == nil { order.append(label) }
            counts[label, default: 0] += 1
        }
        let ranked = order.sorted { counts[$0, default: 0] != counts[$1, default: 0] ? counts[$0, default: 0] > counts[$1, default: 0] : $0 < $1 }
        var lines = ["Grouped by \(JSONPathSegment.render(path)):"]
        for label in ranked.prefix(max(limit, 30)) { lines.append("  \(JSONText.quote(label)): \(JSONText.count(counts[label] ?? 0))") }
        if ranked.count > max(limit, 30) { lines.append("  … and \(ranked.count - max(limit, 30)) more distinct values") }
        if missing > 0 { lines.append("  (no value at that path): \(JSONText.count(missing))") }
        return lines
    }
}
