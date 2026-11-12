// JSONParser.swift
// ChappieCore
//
// Parser for JSON and JSONC (comments and trailing commas are accepted).
// It never builds Swift values: it records byte ranges, which is all the tools need.
//
// WHY AN EXPLICIT STACK, NOT RECURSION:
// Tools run on Swift Concurrency worker threads whose stacks are small (hundreds of KB). A recursive
// descent parser overflowed that stack at roughly 190 nested arrays and killed the whole process
// (SIGBUS in the guard region), long before the depth limit was reached. Open containers live in an
// array on the heap instead, so depth costs memory, not stack, and maxDepth is a plain limit.

import Foundation

public struct JSONParseError: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public let offset: Int
    public let line: Int
    public let column: Int

    public var errorDescription: String? {
        "Invalid JSON at line \(line), column \(column) (byte \(offset)): \(message)"
    }
}

struct JSONParser {
    private let bytes: [UInt8]
    private var pos = 0
    private var nodes: [JSONNode] = []
    private var facts = JSONLexicalFacts()
    private var bomLength = 0

    /// Deeper documents are refused with an error.
    static let maxDepth = 512

    /// A container that has been opened and not yet closed.
    private struct Frame {
        let index: Int
        let isObject: Bool
        var seen = Set<String>()
    }

    /// What the next value is attached to.
    private struct Pending {
        let parent: Int
        let key: String?
        let keyStart: Int
        let keyEnd: Int
    }

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    // MARK: Entry

    mutating func parseDocument() throws -> JSONDocument {
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            bomLength = 3
            pos = 3
        }
        nodes.reserveCapacity(max(16, bytes.count / 12))
        try skipTrivia()
        guard pos < bytes.count else { throw fail("The file is empty, there is no JSON value") }
        try parseTree()
        try skipTrivia()
        if pos < bytes.count { throw fail("Unexpected content after the top-level value") }
        return JSONDocument(bytes: bytes, nodes: nodes, facts: facts, bomLength: bomLength)
    }

    // MARK: Tree

    /// Reads one value together with everything inside it.
    private mutating func parseTree() throws {
        var stack: [Frame] = []
        var next: Pending? = Pending(parent: -1, key: nil, keyStart: -1, keyEnd: -1)

        while true {
            if let pending = next {
                next = nil
                if try openValue(pending, stack: &stack) {
                    next = try readMemberStart(&stack)
                    continue
                }
            }

            // A value just ended: continue the enclosing container, or finish at the top.
            guard let top = stack.last else { return }
            try skipTrivia()
            let close: UInt8 = top.isObject ? 0x7D : 0x5D
            switch peek() {
            case 0x2C:
                pos += 1
                try skipTrivia()
                if peek() == close {
                    facts.hasTrailingCommas = true
                    closeTop(&stack)
                } else {
                    next = try readMemberStart(&stack)
                }
            case close:
                closeTop(&stack)
            default:
                throw fail(top.isObject ? "',' or '}' was expected" : "',' or ']' was expected")
            }
        }
    }

    /// Records the value at `pos`. Returns true when it is a non-empty container that stays open.
    private mutating func openValue(_ pending: Pending, stack: inout [Frame]) throws -> Bool {
        let depth = stack.count
        guard depth <= Self.maxDepth else { throw fail("Nesting is deeper than \(Self.maxDepth) levels") }
        guard pos < bytes.count else { throw fail("Unexpected end of file, a value was expected") }
        guard nodes.count < JSONDocument.maxNodes else {
            throw fail("The file holds more than \(JSONDocument.maxNodes) values, too many to index")
        }

        let kind: JSONKind
        switch bytes[pos] {
        case 0x7B: kind = .object
        case 0x5B: kind = .array
        case 0x22: kind = .string
        case 0x74, 0x66: kind = .bool
        case 0x6E: kind = .null
        case 0x2D, 0x30...0x39: kind = .number
        default: throw fail("Unexpected character '\(describe(bytes[pos]))', a value was expected")
        }

        let index = nodes.count
        nodes.append(JSONNode(kind: kind, start: pos, end: pos, parent: pending.parent, depth: depth,
                              key: pending.key, keyStart: pending.keyStart, keyEnd: pending.keyEnd, children: []))
        if pending.parent >= 0 { nodes[pending.parent].children.append(index) }

        switch kind {
        case .object, .array:
            let isObject = kind == .object
            pos += 1
            let afterOpen = pos
            try skipTrivia()
            if peek() == (isObject ? 0x7D : 0x5D) {
                classifyEmpty(open: afterOpen, isObject: isObject)
                pos += 1
                nodes[index].end = pos
                return false
            }
            stack.append(Frame(index: index, isObject: isObject))
            return true
        case .string: try scanString()
        case .number: try scanNumber()
        case .bool: try scanLiteral(bytes[pos] == 0x74 ? "true" : "false")
        case .null: try scanLiteral("null")
        }
        nodes[index].end = pos
        return false
    }

    /// Reads what comes before the next member's value: an object key and ':' (nothing for an array).
    private mutating func readMemberStart(_ stack: inout [Frame]) throws -> Pending {
        let last = stack.count - 1
        let frame = stack[last]
        try skipTrivia()
        guard frame.isObject else {
            return Pending(parent: frame.index, key: nil, keyStart: -1, keyEnd: -1)
        }
        guard peek() == 0x22 else { throw fail("An object key in double quotes was expected") }
        let keyStart = pos
        try scanString()
        let keyEnd = pos
        let key = JSONStringDecoder.decode(bytes, from: keyStart + 1, to: keyEnd - 1)
        if !stack[last].seen.insert(key).inserted { facts.hasDuplicateKeys = true }
        try skipTrivia()
        guard peek() == 0x3A else { throw fail("':' was expected after the key") }
        pos += 1
        try skipTrivia()
        return Pending(parent: frame.index, key: key, keyStart: keyStart, keyEnd: keyEnd)
    }

    /// Consumes the closing bracket of the innermost container.
    private mutating func closeTop(_ stack: inout [Frame]) {
        pos += 1
        if let frame = stack.popLast() { nodes[frame.index].end = pos }
    }

    // MARK: Scalars

    /// Moves past the closing quote. Records the escape facts the style detector needs.
    private mutating func scanString() throws {
        pos += 1
        while pos < bytes.count {
            let byte = bytes[pos]
            switch byte {
            case 0x22:
                pos += 1
                return
            case 0x5C:
                guard pos + 1 < bytes.count else { throw fail("The string ends inside an escape") }
                let escape = bytes[pos + 1]
                switch escape {
                case 0x2F:
                    facts.hasEscapedSlash = true
                    pos += 2
                case 0x22, 0x5C, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    pos += 2
                case 0x75:
                    guard let value = JSONStringDecoder.hex4(bytes, at: pos + 2) else {
                        throw fail("\\u must be followed by four hex digits")
                    }
                    if value >= 0x80 { facts.hasUnicodeEscapes = true }
                    pos += 6
                default:
                    throw fail("Unknown escape '\\\(describe(escape))'")
                }
            case 0x2F:
                facts.hasPlainSlash = true
                pos += 1
            case 0x00..<0x20:
                throw fail("A raw control character inside a string, it must be escaped")
            case 0x80...0xFF:
                facts.hasRawNonASCII = true
                pos += 1
            default:
                pos += 1
            }
        }
        throw fail("The string is not closed")
    }

    private mutating func scanNumber() throws {
        if peek() == 0x2D { pos += 1 }
        guard let first = peek(), (0x30...0x39).contains(first) else { throw fail("A digit was expected in the number") }
        if first == 0x30 {
            pos += 1
        } else {
            skipDigits()
        }
        if peek() == 0x2E {
            pos += 1
            guard let digit = peek(), (0x30...0x39).contains(digit) else { throw fail("A digit was expected after '.'") }
            skipDigits()
        }
        if peek() == 0x65 || peek() == 0x45 {
            pos += 1
            if peek() == 0x2B || peek() == 0x2D { pos += 1 }
            guard let digit = peek(), (0x30...0x39).contains(digit) else { throw fail("A digit was expected in the exponent") }
            skipDigits()
        }
    }

    private mutating func scanLiteral(_ word: String) throws {
        let expected = Array(word.utf8)
        guard pos + expected.count <= bytes.count, Array(bytes[pos..<pos + expected.count]) == expected else {
            throw fail("'\(word)' was expected")
        }
        pos += expected.count
        if let next = peek(), isIdentifierByte(next) { throw fail("Unexpected character after '\(word)'") }
    }

    private mutating func skipDigits() {
        while let byte = peek(), (0x30...0x39).contains(byte) { pos += 1 }
    }

    // MARK: Trivia

    /// Skips whitespace and comments. Comments are a JSONC extension, recorded in the facts.
    private mutating func skipTrivia() throws {
        while pos < bytes.count {
            switch bytes[pos] {
            case 0x20, 0x09, 0x0A, 0x0D:
                pos += 1
            case 0x2F:
                guard pos + 1 < bytes.count else { throw fail("A stray '/'") }
                if bytes[pos + 1] == 0x2F {
                    facts.hasComments = true
                    while pos < bytes.count, bytes[pos] != 0x0A { pos += 1 }
                } else if bytes[pos + 1] == 0x2A {
                    facts.hasComments = true
                    let commentStart = pos
                    pos += 2
                    var closed = false
                    while pos + 1 < bytes.count {
                        if bytes[pos] == 0x2A, bytes[pos + 1] == 0x2F { pos += 2; closed = true; break }
                        pos += 1
                    }
                    if !closed {
                        pos = commentStart
                        throw fail("A /* comment is not closed")
                    }
                } else {
                    throw fail("A stray '/'")
                }
            default:
                return
            }
        }
    }

    /// Records how an empty container was written: `{}`, `{ }` or split over lines.
    private mutating func classifyEmpty(open: Int, isObject: Bool) {
        let gap = bytes[open..<pos]
        var form = JSONEmptyFormCounts()
        if gap.isEmpty {
            form.compact = 1
        } else if gap.contains(0x0A) {
            form.multiline = 1
        } else {
            form.spaced = 1
        }
        if isObject {
            facts.emptyObjects.compact += form.compact
            facts.emptyObjects.spaced += form.spaced
            facts.emptyObjects.multiline += form.multiline
        } else {
            facts.emptyArrays.compact += form.compact
            facts.emptyArrays.spaced += form.spaced
            facts.emptyArrays.multiline += form.multiline
        }
    }

    // MARK: Helpers

    private func peek() -> UInt8? { pos < bytes.count ? bytes[pos] : nil }

    private func isIdentifierByte(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || byte == 0x5F
    }

    private func describe(_ byte: UInt8) -> String {
        byte >= 0x20 && byte < 0x7F ? String(UnicodeScalar(byte)) : String(format: "0x%02X", byte)
    }

    private func fail(_ message: String) -> JSONParseError {
        var line = 1
        var lineStart = 0
        let limit = min(pos, bytes.count)
        var index = 0
        while index < limit {
            if bytes[index] == 0x0A { line += 1; lineStart = index + 1 }
            index += 1
        }
        return JSONParseError(message: message, offset: pos, line: line, column: pos - lineStart + 1)
    }
}
