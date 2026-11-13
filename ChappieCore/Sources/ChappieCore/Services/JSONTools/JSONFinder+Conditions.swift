// JSONFinder+Conditions.swift
// ChappieCore
//
// The conditions of json_find: the AND form (default) and the OR form (match_any), and the helpers
// both share. Kept apart from JSONFinder so the search and its output stay short.

import Foundation

extension JSONFinder {

    static func passesAll(_ doc: JSONDocument, _ index: Int, _ query: JSONFindQuery) -> Bool {
        let node = doc.nodes[index]
        if let key = query.key {
            guard let own = node.key, key.matches(own) else { return false }
        }
        if let kind = query.kind, node.kind != kind { return false }
        if let has = query.has, doc.resolve(has, from: index).isEmpty { return false }
        if let missing = query.missing, !doc.resolve(missing, from: index).isEmpty { return false }
        guard query.hasValueCondition else { return true }

        let candidates = candidateTexts(doc, index, query)
        if let equals = query.equals, !candidates.contains(where: { same($0, equals, query) }) { return false }
        if let notEquals = query.notEquals, candidates.contains(where: { same($0, notEquals, query) }) { return false }
        if let part = query.contains, !candidates.contains(where: { has($0, part, query) }) { return false }
        if let part = query.notContains, candidates.contains(where: { has($0, part, query) }) { return false }
        if let sameAs = query.sameAs, !comparesWith(doc, index, candidates, sameAs, query) { return false }
        return true
    }

    static func passesAny(_ doc: JSONDocument, _ index: Int, _ query: JSONFindQuery) -> Bool {
        let node = doc.nodes[index]
        var tests = 0
        if let key = query.key {
            tests += 1
            if let own = node.key, key.matches(own) { return true }
        }
        if let kind = query.kind {
            tests += 1
            if node.kind == kind { return true }
        }
        if let has = query.has {
            tests += 1
            if !doc.resolve(has, from: index).isEmpty { return true }
        }
        if let missing = query.missing {
            tests += 1
            if doc.resolve(missing, from: index).isEmpty { return true }
        }
        guard query.hasValueCondition else { return tests == 0 }

        let candidates = candidateTexts(doc, index, query)
        if let equals = query.equals {
            tests += 1
            if candidates.contains(where: { same($0, equals, query) }) { return true }
        }
        if let notEquals = query.notEquals {
            tests += 1
            if !candidates.contains(where: { same($0, notEquals, query) }) { return true }
        }
        if let part = query.contains {
            tests += 1
            if candidates.contains(where: { has($0, part, query) }) { return true }
        }
        if let part = query.notContains {
            tests += 1
            if !candidates.contains(where: { has($0, part, query) }) { return true }
        }
        if let sameAs = query.sameAs {
            tests += 1
            if comparesWith(doc, index, candidates, sameAs, query) { return true }
        }
        return false
    }

    /// The scalar texts the value conditions look at, one per candidate at `value_at`.
    static func candidateTexts(_ doc: JSONDocument, _ index: Int, _ query: JSONFindQuery) -> [String] {
        doc.resolve(query.valueAt, from: index).filter { isScalar(doc, $0) }.map { text(doc, $0) }
    }

    /// `same_as`: does a value at `value_at` equal a value at another path of the SAME subject?
    /// Closed when either side is empty, so a subject that lacks the other path never matches.
    static func comparesWith(
        _ doc: JSONDocument, _ index: Int, _ candidates: [String],
        _ other: [JSONPathSegment], _ query: JSONFindQuery
    ) -> Bool {
        let others = doc.resolve(other, from: index).filter { isScalar(doc, $0) }.map { text(doc, $0) }
        guard !others.isEmpty else { return false }
        for left in candidates {
            for right in others where same(left, right, query) { return true }
        }
        return false
    }

    static func isScalar(_ doc: JSONDocument, _ index: Int) -> Bool {
        let kind = doc.nodes[index].kind
        return kind != .object && kind != .array
    }

    /// Strings decoded, every other scalar exactly as written (5, true, null).
    static func text(_ doc: JSONDocument, _ index: Int) -> String {
        doc.stringValue(of: index) ?? doc.rawText(of: index)
    }

    static func same(_ left: String, _ right: String, _ query: JSONFindQuery) -> Bool {
        query.ignoreCase ? left.lowercased() == right.lowercased() : left == right
    }

    static func has(_ whole: String, _ part: String, _ query: JSONFindQuery) -> Bool {
        query.ignoreCase ? whole.lowercased().contains(part.lowercased()) : whole.contains(part)
    }
}
