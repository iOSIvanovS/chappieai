// JSONDocument.swift
// ChappieCore
//
// A parsed JSON file that remembers WHERE every value lives in the original bytes.
// WHY: json_edit splices only the changed fragment and leaves every other byte untouched,
// so the file keeps its exact style (indent, separators, escaping, key order) without a serializer.
// Nodes are stored in a flat array in document order: index 0 is the root, a parent always
// precedes its children, and start offsets grow with the index.

import Foundation

public enum JSONKind: String, Sendable, Equatable {
    case object, array, string, number, bool, null
}

public struct JSONNode: Sendable {
    public let kind: JSONKind
    /// First byte of the value token (the opening quote, brace, bracket or first character).
    public internal(set) var start: Int
    /// One past the last byte of the value token.
    public internal(set) var end: Int
    /// Index of the parent node, -1 for the root.
    public let parent: Int
    /// Root is 0, its children are 1, and so on.
    public let depth: Int
    /// Decoded key when this node is an object member, nil for the root and array elements.
    public let key: String?
    /// Byte range of the key token including its quotes. Both are -1 for non-members.
    public let keyStart: Int
    public let keyEnd: Int
    /// Child node indices in file order (members of an object or elements of an array).
    public internal(set) var children: [Int]

    public var isMember: Bool { key != nil }
    /// Where the member begins in the file: the key for members, the value otherwise.
    public var memberStart: Int { key != nil ? keyStart : start }
}

/// Counts of how empty containers are written, used to copy the style when inserting.
public struct JSONEmptyFormCounts: Sendable, Equatable {
    public var compact = 0     // "{}"
    public var spaced = 0      // "{ }"
    public var multiline = 0   // "{" newline ... "}"
}

/// Facts collected while scanning, before any style decision is made.
public struct JSONLexicalFacts: Sendable, Equatable {
    public var hasComments = false
    public var hasTrailingCommas = false
    public var hasDuplicateKeys = false
    public var hasEscapedSlash = false      // "\/" inside a string
    public var hasPlainSlash = false        // "/" inside a string
    public var hasUnicodeEscapes = false    // "\uXXXX" with a non-ASCII value
    public var hasRawNonASCII = false       // a non-ASCII character written as is
    public var emptyObjects = JSONEmptyFormCounts()
    public var emptyArrays = JSONEmptyFormCounts()
}

public struct JSONDocument: Sendable {
    public let bytes: [UInt8]
    public let nodes: [JSONNode]
    public let facts: JSONLexicalFacts
    /// Byte offsets where each line begins (first element is always 0).
    public let lineStarts: [Int]
    /// 3 when the file starts with a UTF-8 BOM, otherwise 0. Offsets stay absolute.
    public let bomLength: Int

    public var root: Int { 0 }
    public var rootNode: JSONNode { nodes[0] }

    // MARK: Parsing

    public static func parse(_ data: Data) throws -> JSONDocument {
        var parser = JSONParser(bytes: [UInt8](data))
        return try parser.parseDocument()
    }

    public static func parse(_ text: String) throws -> JSONDocument {
        try parse(Data(text.utf8))
    }

    init(bytes: [UInt8], nodes: [JSONNode], facts: JSONLexicalFacts, bomLength: Int) {
        self.bytes = bytes
        self.nodes = nodes
        self.facts = facts
        self.bomLength = bomLength
        var starts = [0]
        for (offset, byte) in bytes.enumerated() where byte == 0x0A {
            starts.append(offset + 1)
        }
        self.lineStarts = starts
    }

    // MARK: Access

    public func node(_ index: Int) -> JSONNode { nodes[index] }

    /// The first member with this key. Duplicate keys are legal JSON; `facts.hasDuplicateKeys` tells.
    public func member(_ key: String, of index: Int) -> Int? {
        guard nodes[index].kind == .object else { return nil }
        for child in nodes[index].children where nodes[child].key == key { return child }
        return nil
    }

    public func element(_ position: Int, of index: Int) -> Int? {
        guard nodes[index].kind == .array else { return nil }
        let children = nodes[index].children
        let resolved = position < 0 ? children.count + position : position
        return children.indices.contains(resolved) ? children[resolved] : nil
    }

    /// The value's source text exactly as written.
    public func rawText(of index: Int) -> String {
        let node = nodes[index]
        return String(decoding: bytes[node.start..<node.end], as: UTF8.self)
    }

    /// Decoded content of a string node, nil for any other kind.
    public func stringValue(of index: Int) -> String? {
        let node = nodes[index]
        guard node.kind == .string else { return nil }
        return JSONStringDecoder.decode(bytes, from: node.start + 1, to: node.end - 1)
    }

    /// 1-based line number of a byte offset.
    public func lineNumber(at offset: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    /// Number of lines in the file; a trailing newline does not start an extra line.
    public var lineCount: Int {
        guard let last = bytes.last else { return 0 }
        return last == 0x0A ? lineStarts.count - 1 : lineStarts.count
    }

    /// Node indices from the root to this node.
    public func ancestry(of index: Int) -> [Int] {
        var chain: [Int] = []
        var current = index
        while current >= 0 {
            chain.append(current)
            current = nodes[current].parent
        }
        return chain.reversed()
    }
}
