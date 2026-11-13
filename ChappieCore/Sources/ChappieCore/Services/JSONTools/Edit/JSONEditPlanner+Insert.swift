// JSONEditPlanner+Insert.swift
// ChappieCore
//
// Adding members. Position "auto" keeps an alphabetical object alphabetical and otherwise appends.
// Inserts into one container are grouped by the place they land at, so several new keys in one call
// produce ONE splice per place with the commas right; a new key in an empty container replaces
// the whole container with one that holds all of them.

import Foundation

extension JSONEditPlanner {

    mutating func queueInsert(_ op: JSONEditOp, _ key: String?, _ value: JSONEditValue, _ position: JSONEditPosition) {
        guard let parent = single(op) else { return }
        let kind = doc.nodes[parent].kind
        guard kind == .object || kind == .array else {
            problem("\(op.label): insert goes into an object or an array, this is a \(kind.rawValue).")
            return
        }
        if kind == .object && key == nil {
            problem("\(op.label): inserting into an object needs 'key'.")
            return
        }
        if kind == .array && key != nil {
            problem("\(op.label): an array item has no key; remove 'key' and use 'position' if the place matters.")
            return
        }
        insertions[parent, default: []].append(PendingInsert(op: op, key: key, value: value, position: position))
    }

    // MARK: Per container

    private enum SortMode { case bytes, ignoringCase }

    private struct Placed {
        let insert: PendingInsert
        let index: Int
        let bySort: Bool
    }

    mutating func planInsertions() {
        for (parent, items) in insertions.sorted(by: { $0.key < $1.key }) {
            planContainer(parent: parent, items: items)
        }
    }

    private mutating func planContainer(parent: Int, items: [PendingInsert]) {
        let container = doc.nodes[parent]
        let isObject = container.kind == .object
        let children = container.children

        // A new key must not exist yet, and two new keys must differ.
        var fresh = Set<String>()
        var accepted: [PendingInsert] = []
        for item in items {
            if let key = item.key, isObject {
                if doc.member(key, of: parent) != nil {
                    problem("\(item.op.label): the key \(JSONText.quote(key)) already exists; use op \"set\" to change its value.")
                    continue
                }
                if !fresh.insert(key).inserted {
                    problem("\(item.op.label): another operation of this call also inserts the key \(JSONText.quote(key)).")
                    continue
                }
            }
            accepted.append(item)
        }

        let mode = isObject ? sortMode(of: parent) : nil
        var placed: [Placed] = []
        for item in accepted {
            guard let (index, bySort) = resolvePosition(item, parent: parent, mode: mode) else { continue }
            placed.append(Placed(insert: item, index: index, bySort: bySort))
        }
        guard !placed.isEmpty else { return }

        placed.sort { left, right in
            if left.index != right.index { return left.index < right.index }
            if left.bySort && right.bySort, let a = left.insert.key, let b = right.insert.key {
                return less(a, b, mode: mode)
            }
            return left.insert.op.number < right.insert.op.number
        }

        if children.isEmpty {
            planIntoEmpty(parent: parent, placed: placed)
        } else {
            planIntoFilled(parent: parent, placed: placed)
        }
        for entry in placed {
            if let key = entry.insert.key, let path = stablePath(of: parent) {
                addCheck(.value(path: path + [.key(key)], expected: entry.insert.value, op: entry.insert.op.number))
            }
        }
    }

    // MARK: Position

    private func sortMode(of object: Int) -> SortMode? {
        let count = doc.nodes[object].children.count
        if count >= 2 {
            if JSONStyle.isSorted(object: object, in: doc) { return .bytes }
            if JSONStyle.isSorted(object: object, in: doc, ignoringCase: true) { return .ignoringCase }
            return nil
        }
        switch style.keyOrder {
        case .sorted: return .bytes
        case .sortedIgnoringCase: return .ignoringCase
        default: return nil
        }
    }

    private func less(_ a: String, _ b: String, mode: SortMode?) -> Bool {
        if mode == .ignoringCase { return a.lowercased().utf8.lexicographicallyPrecedes(b.lowercased().utf8) }
        return a.utf8.lexicographicallyPrecedes(b.utf8)
    }

    /// Where among the existing members the new one goes, and whether the alphabet decided it.
    private mutating func resolvePosition(_ item: PendingInsert, parent: Int, mode: SortMode?) -> (Int, Bool)? {
        let children = doc.nodes[parent].children
        let count = children.count
        let isObject = doc.nodes[parent].kind == .object
        let label = item.op.label

        func sortedIndex() -> Int {
            guard let key = item.key else { return count }
            for (offset, child) in children.enumerated() {
                if let other = doc.nodes[child].key, less(key, other, mode: mode) { return offset }
            }
            return count
        }
        func member(_ anchor: String) -> Int? {
            children.firstIndex { doc.nodes[$0].key == anchor }
        }

        switch item.position {
        case .start: return (0, false)
        case .end: return (count, false)
        case .index(let value):
            // Paths already count from the end when negative (see JSONDocument.element), so a
            // position does too: one rule for the whole toolset beats two that look alike.
            let resolved = value < 0 ? count + value : value
            guard (0...count).contains(resolved) else {
                let allowed = count == 0 ? "0" : "0...\(count) or -1...-\(count)"
                problem("\(label): position \(value) is outside \(allowed). Use \"end\" to append.")
                return nil
            }
            return (resolved, false)
        case .after(let anchor), .before(let anchor):
            guard isObject else {
                problem("\(label): 'position' names the key \(JSONText.quote(anchor)), but this is an array and an array item has no key. Use \"start\", \"end\" or an integer index.")
                return nil
            }
            guard let found = member(anchor) else {
                problem("\(label): 'position' names the key \(JSONText.quote(anchor)), which is not in this object.")
                return nil
            }
            if case .after = item.position { return (found + 1, false) }
            return (found, false)
        case .sorted:
            guard isObject, mode != nil else {
                problem("\(label): position \"sorted\" needs an alphabetical object, and this one is not. Use \"end\", \"start\", {\"after\":\"key\"} or {\"before\":\"key\"}.")
                return nil
            }
            return (sortedIndex(), true)
        case .auto:
            if isObject, mode != nil { return (sortedIndex(), true) }
            return (count, false)
        }
    }

    // MARK: Text

    private func memberText(_ item: PendingInsert, inner: String, inline: Bool) -> String {
        let value = renderer.render(item.value.doc, item.value.node, baseIndent: inner, inline: inline)
        guard let key = item.key else { return value }
        return renderer.quote(key) + style.keySeparator + value
    }

    private mutating func planIntoEmpty(parent: Int, placed: [Placed]) {
        let container = doc.nodes[parent]
        if hasComment(from: container.start + 1, to: container.end - 1) {
            problem("\(placed[0].insert.op.label): the empty container holds a comment that would be lost. Add the member with patch_file instead.")
            return
        }
        let isObject = container.kind == .object
        let base = lineIndent(at: container.memberStart)
        let multiline = renderer.isMultiline(object: isObject)
        let inner = base + renderer.unit
        let open = isObject ? "{" : "[", close = isObject ? "}" : "]"
        let parts = placed.map { memberText($0.insert, inner: multiline ? inner : base, inline: !multiline) }
        let text: String
        if multiline {
            text = open + renderer.lineEnding + inner + parts.joined(separator: "," + renderer.lineEnding + inner) + renderer.lineEnding + base + close
        } else {
            text = open + parts.joined(separator: style.isMinified ? "," : ", ") + close
        }
        addSplice(JSONSplice(start: container.start, end: container.end, text: Array(text.utf8), ops: placed.map(\.insert.op.number)))
    }

    private mutating func planIntoFilled(parent: Int, placed: [Placed]) {
        let container = doc.nodes[parent]
        let children = container.children
        let first = doc.nodes[children[0]]
        let multiline = doc.bytes[(container.start + 1)..<first.memberStart].contains(0x0A)
        let eol = renderer.lineEnding
        let separator = style.isMinified ? "" : " "

        var inner = lineIndent(at: container.memberStart) + renderer.unit
        let firstLine = doc.lineStarts[doc.lineNumber(at: first.memberStart) - 1]
        if multiline, doc.bytes[firstLine..<first.memberStart].allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
            inner = String(decoding: doc.bytes[firstLine..<first.memberStart], as: UTF8.self)
        }

        var cursor = 0
        while cursor < placed.count {
            let index = placed[cursor].index
            var end = cursor
            while end < placed.count, placed[end].index == index { end += 1 }
            let group = Array(placed[cursor..<end])
            cursor = end

            let parts = group.map { memberText($0.insert, inner: multiline ? inner : "", inline: !multiline) }
            let ops = group.map(\.insert.op.number)
            let joiner = multiline ? "," + eol + inner : "," + separator
            if index == children.count {
                let text = parts.map { joiner + $0 }.joined()
                let at = doc.nodes[children[children.count - 1]].end
                addSplice(JSONSplice(start: at, end: at, text: Array(text.utf8), ops: ops))
            } else {
                let at = doc.nodes[children[index]].memberStart
                let gapStart = index == 0 ? container.start + 1 : doc.nodes[children[index - 1]].end
                if hasComment(from: gapStart, to: at) {
                    problem("\(group[0].insert.op.label): there is a comment at that place and the new member would end up under the wrong one. Choose another position or use patch_file.")
                    continue
                }
                let text = parts.map { $0 + joiner }.joined()
                addSplice(JSONSplice(start: at, end: at, text: Array(text.utf8), ops: ops))
            }
        }
    }
}
