// JSONEditPlanner.swift
// ChappieCore
//
// Turns the operations of one json_edit call into splices over the ORIGINAL bytes. All paths refer
// to the original file (never to a half-edited one), so the order of the operations does not matter.
// Every problem found while planning is collected, so the model fixes everything in one round.
//
// set / rename: one splice each. delete / insert: grouped per parent container (see +Delete / +Insert),
// because removing or adding a member also moves a comma.

import Foundation

/// What must be true in the file after the edit, checked on the re-parsed result.
enum JSONEditCheck {
    case value(path: [JSONPathSegment], expected: JSONEditValue, op: Int)
    case absent(path: [JSONPathSegment], op: Int)
}

struct JSONEditPlanner {

    let doc: JSONDocument
    let style: JSONStyle
    let renderer: JSONValueRenderer

    private(set) var splices: [JSONSplice] = []
    private(set) var notes: [String] = []
    private(set) var problems: [String] = []
    private(set) var checks: [JSONEditCheck] = []

    /// Parent index -> members to remove.
    var deletions: [Int: [(node: Int, op: Int)]] = [:]
    /// Parent index -> inserts waiting for their position.
    var insertions: [Int: [PendingInsert]] = [:]
    /// Node index -> number of the op that deletes it (two ops deleting one value is a mistake).
    private var deleted: [Int: Int] = [:]

    struct PendingInsert {
        let op: JSONEditOp
        let key: String?
        let value: JSONEditValue
        let position: JSONEditPosition
    }

    init(doc: JSONDocument, style: JSONStyle) {
        self.doc = doc
        self.style = style
        self.renderer = JSONValueRenderer(style: style)
    }

    // MARK: Entry

    mutating func plan(_ ops: [JSONEditOp]) {
        for op in ops {
            switch op.action {
            case .set(let value): planSet(op, value)
            case .rename(let newKey): planRename(op, newKey)
            case .delete: planDelete(op)
            case .insert(let key, let value, let position): queueInsert(op, key, value, position)
            }
        }
        planDeletions()
        planInsertions()
    }

    // MARK: Shared helpers

    mutating func addSplice(_ splice: JSONSplice) { splices.append(splice) }
    mutating func note(_ text: String) { notes.append(text) }
    mutating func problem(_ text: String) { problems.append(text) }
    mutating func addCheck(_ check: JSONEditCheck) { checks.append(check) }

    /// The one node an operation points at; records a problem otherwise.
    mutating func single(_ op: JSONEditOp) -> Int? {
        let found = doc.resolve(op.at)
        if found.isEmpty {
            var text = "\(op.label): " + JSONFragment.missingPath(doc, op.at).message
            if case .set = op.action, let last = op.at.last, case .key(let key) = last {
                let parent = Array(op.at.dropLast())
                if let node = doc.resolve(parent).first, doc.resolve(parent).count == 1, doc.nodes[node].kind == .object {
                    text += " To add a new key use op \"insert\" with at \(JSONPathSegment.render(parent)) and key \(JSONText.quote(key))."
                }
            }
            problem(text)
            return nil
        }
        if found.count > 1 {
            problem("\(op.label): the path matches \(JSONText.count(found.count)) places, and one operation changes exactly one value. Give a concrete path, or one operation per place.")
            return nil
        }
        return found[0]
    }

    /// False (with a problem recorded) when the current value is not the one `expect` names.
    mutating func matchesExpect(_ op: JSONEditOp, _ node: Int) -> Bool {
        guard let expect = op.expect else { return true }
        if JSONValueEquality.equal(doc, node, expect.doc, expect.node) { return true }
        problem("\(op.label): the current value is \(describe(node)), not what 'expect' says. The file may have changed since you looked; read it again.")
        return false
    }

    func describe(_ node: Int) -> String {
        let kind = doc.nodes[node].kind
        return kind == .object || kind == .array ? JSONText.summary(doc, node) : JSONText.scalarPreview(doc, node, limit: 120)
    }

    /// Whitespace at the start of the line that contains `offset`.
    func lineIndent(at offset: Int) -> String {
        var cursor = doc.lineStarts[doc.lineNumber(at: offset) - 1]
        let begin = cursor
        while cursor < doc.bytes.count, doc.bytes[cursor] == 0x20 || doc.bytes[cursor] == 0x09 { cursor += 1 }
        return String(decoding: doc.bytes[begin..<cursor], as: UTF8.self)
    }

    /// True when the whole container sits on one line.
    func isInline(_ container: Int) -> Bool {
        let node = doc.nodes[container]
        return doc.lineNumber(at: node.start) == doc.lineNumber(at: max(node.start, node.end - 1))
    }

    /// True when the bytes of a gap (between tokens, so only blanks, commas and comments) hold a comment.
    func hasComment(from: Int, to: Int) -> Bool {
        guard from < to else { return false }
        return doc.bytes[from..<to].contains(0x2F)
    }

    /// Path usable for the after-the-edit check; nil when it goes through an array position,
    /// which other operations of the same call may shift.
    func stablePath(of node: Int) -> [JSONPathSegment]? {
        let path = doc.path(of: node)
        for segment in path { if case .index = segment { return nil } }
        return path
    }

    // MARK: set

    private mutating func planSet(_ op: JSONEditOp, _ value: JSONEditValue) {
        guard let node = single(op), matchesExpect(op, node) else { return }
        let target = doc.nodes[node]
        let text = renderer.render(
            value.doc, value.node, baseIndent: lineIndent(at: target.memberStart),
            inline: target.parent >= 0 && isInline(target.parent)
        )
        let bytes = Array(text.utf8)
        if bytes == Array(doc.bytes[target.start..<target.end]) {
            note("\(op.label): the value is already exactly this, nothing to change.")
            return
        }
        addSplice(JSONSplice(start: target.start, end: target.end, text: bytes, ops: [op.number]))
        if let path = stablePath(of: node) { addCheck(.value(path: path, expected: value, op: op.number)) }
    }

    // MARK: rename

    private mutating func planRename(_ op: JSONEditOp, _ newKey: String) {
        guard let node = single(op), matchesExpect(op, node) else { return }
        let target = doc.nodes[node]
        guard let oldKey = target.key else {
            problem("\(op.label): only an object member has a key; this is an array item or the root.")
            return
        }
        if oldKey == newKey {
            note("\(op.label): the key is already named so, nothing to change.")
            return
        }
        if let other = doc.member(newKey, of: target.parent), other != node {
            problem("\(op.label): the object already has a key \(JSONText.quote(newKey)).")
            return
        }
        addSplice(JSONSplice(start: target.keyStart, end: target.keyEnd, text: Array(renderer.quote(newKey).utf8), ops: [op.number]))
        if JSONStyle.isSorted(object: target.parent, in: doc) {
            note("\(op.label): the object was alphabetical; the new name may now stand out of order.")
        }
        if let path = stablePath(of: node) {
            addCheck(.absent(path: path, op: op.number))
            addCheck(.value(path: Array(path.dropLast()) + [.key(newKey)], expected: JSONEditValue(doc: doc, node: node), op: op.number))
        }
    }

    // MARK: delete (collected here, turned into splices in +Delete)

    private mutating func planDelete(_ op: JSONEditOp) {
        guard let node = single(op), matchesExpect(op, node) else { return }
        let parent = doc.nodes[node].parent
        guard parent >= 0 else {
            problem("\(op.label): the whole document cannot be deleted.")
            return
        }
        if let first = deleted[node] {
            problem("\(op.label): edit \(first) already deletes this value.")
            return
        }
        deleted[node] = op.number
        deletions[parent, default: []].append((node, op.number))
        if let path = stablePath(of: node) { addCheck(.absent(path: path, op: op.number)) }
    }
}
