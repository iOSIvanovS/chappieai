// JSONPath.swift
// ChappieCore
//
// Paths into a JSON document, written as an ARRAY of segments (not a dotted string):
// real keys such as "chat.send.title" contain dots.
//
//   "name"      exact key (or an array position when the node is an array and the text is an integer)
//   3 / -1      array position; negative counts from the end
//   "add_*"     glob over keys: * any run of characters, ? one character
//   "*"         every member of an object or every element of an array
//   "**"        the node itself and every descendant, at any depth
//   "\*" "\?"   a literal * or ? inside a key ("\\" is a literal backslash)

import Foundation

public struct JSONToolError: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct JSONGlob: Sendable, Equatable {
    enum Token: Sendable, Equatable {
        case star
        case any
        case literal(Unicode.Scalar)
    }

    let tokens: [Token]
    /// The segment as the caller wrote it, kept to print the path back.
    let source: String

    var matchesEverything: Bool { tokens == [.star] }

    /// Compiles a pattern. `literal` is the text with escapes removed, the key to use when there is no wildcard.
    static func compile(_ text: String) -> (glob: JSONGlob, literal: String, hasWildcard: Bool) {
        var tokens: [Token] = []
        var literal = String.UnicodeScalarView()
        var wildcard = false
        var scalars = text.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            switch scalar {
            case "\\":
                let escaped = scalars.next() ?? "\\"
                tokens.append(.literal(escaped))
                literal.append(escaped)
            case "*":
                tokens.append(.star)
                wildcard = true
            case "?":
                tokens.append(.any)
                wildcard = true
            default:
                tokens.append(.literal(scalar))
                literal.append(scalar)
            }
        }
        return (JSONGlob(tokens: tokens, source: text), String(literal), wildcard)
    }

    func matches(_ key: String) -> Bool {
        if matchesEverything { return true }
        let text = Array(key.unicodeScalars)
        var p = 0, t = 0, starP = -1, starT = 0
        while t < text.count {
            if p < tokens.count {
                switch tokens[p] {
                case .star:
                    starP = p; starT = t; p += 1
                    continue
                case .any:
                    p += 1; t += 1
                    continue
                case .literal(let scalar):
                    if scalar == text[t] { p += 1; t += 1; continue }
                }
            }
            guard starP >= 0 else { return false }
            starT += 1
            t = starT
            p = starP + 1
        }
        while p < tokens.count, tokens[p] == .star { p += 1 }
        return p == tokens.count
    }
}

public enum JSONPathSegment: Sendable, Equatable {
    case key(String)
    case index(Int)
    case glob(JSONGlob)
    case anyDepth

    /// One text segment: "**", a glob, or an exact key (backslash escapes applied).
    public static func make(_ text: String) -> JSONPathSegment {
        if text == "**" { return .anyDepth }
        let compiled = JSONGlob.compile(text)
        return compiled.hasWildcard ? .glob(compiled.glob) : .key(compiled.literal)
    }

    // MARK: Parsing

    static let example = #"["strings", "*", "localizations", "ru"]"#

    /// Reads a path from the text of a JSON array. Empty text is the root.
    public static func parseList(_ text: String, argument: String) throws -> [JSONPathSegment] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        guard let value = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed]) else {
            throw JSONToolError("Argument '\(argument)' must be a JSON array of segments, for example \(example). Got: \(trimmed.prefix(80))")
        }
        return try segments(from: value, argument: argument)
    }

    /// Segments from an already decoded JSON value (an array, or a single string or integer).
    static func segments(from value: Any, argument: String) throws -> [JSONPathSegment] {
        if let list = value as? [Any] {
            return try list.map { try segment(from: $0, argument: argument) }
        }
        return [try segment(from: value, argument: argument)]
    }

    private static func segment(from value: Any, argument: String) throws -> JSONPathSegment {
        if let text = value as? String { return make(text) }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.doubleValue == Double(number.intValue) {
            return .index(number.intValue)
        }
        throw JSONToolError("Argument '\(argument)': every segment must be a string or an integer, for example \(example).")
    }

    // MARK: Printing

    /// The path as JSON array text, ready to be passed back to a json_* tool.
    public static func render(_ segments: [JSONPathSegment]) -> String {
        "[" + segments.map(renderOne).joined(separator: ", ") + "]"
    }

    private static func renderOne(_ segment: JSONPathSegment) -> String {
        switch segment {
        case .key(let key): return JSONText.quote(escapeGlob(key))
        case .index(let position): return String(position)
        case .glob(let glob): return JSONText.quote(glob.source)
        case .anyDepth: return "\"**\""
        }
    }

    private static func escapeGlob(_ key: String) -> String {
        guard key.contains(where: { $0 == "*" || $0 == "?" || $0 == "\\" }) else { return key }
        var out = ""
        for character in key {
            if character == "*" || character == "?" || character == "\\" { out.append("\\") }
            out.append(character)
        }
        return out
    }
}

// MARK: - Resolution

extension JSONDocument {

    /// First index after the last descendant of `index`. Nodes are stored in document order,
    /// so a subtree is the contiguous run of nodes that start before this node ends.
    public func subtreeEnd(of index: Int) -> Int {
        let end = nodes[index].end
        var low = index + 1, high = nodes.count
        while low < high {
            let mid = (low + high) / 2
            if nodes[mid].start < end { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Every node the path reaches from `start`. Wildcards fan out; a path that matches nothing gives [].
    public func resolve(_ segments: [JSONPathSegment], from start: Int = 0) -> [Int] {
        resolve(segments, starting: [start])
    }

    /// Same, beginning from several nodes at once.
    public func resolve(_ segments: [JSONPathSegment], starting: [Int]) -> [Int] {
        var current = starting
        for segment in segments {
            if current.isEmpty { break }
            var next: [Int] = []
            switch segment {
            case .anyDepth:
                var seen = Set<Int>()
                for node in current {
                    for candidate in node..<subtreeEnd(of: node) where seen.insert(candidate).inserted {
                        next.append(candidate)
                    }
                }
            case .key(let key):
                for node in current {
                    if let child = member(key, of: node) {
                        next.append(child)
                    } else if nodes[node].kind == .array, let position = Int(key), let child = element(position, of: node) {
                        next.append(child)
                    }
                }
            case .index(let position):
                for node in current {
                    if let child = element(position, of: node) { next.append(child) }
                }
            case .glob(let glob):
                for node in current {
                    switch nodes[node].kind {
                    case .object:
                        for child in nodes[node].children where glob.matches(nodes[child].key ?? "") { next.append(child) }
                    case .array where glob.matchesEverything:
                        next.append(contentsOf: nodes[node].children)
                    default:
                        break
                    }
                }
            }
            current = next
        }
        return current
    }

    /// The concrete path of a node (keys and array positions, no wildcards).
    public func path(of index: Int) -> [JSONPathSegment] {
        var segments: [JSONPathSegment] = []
        var current = index
        while nodes[current].parent >= 0 {
            let parent = nodes[current].parent
            if let key = nodes[current].key {
                segments.append(.key(key))
            } else {
                segments.append(.index(position(of: current, in: parent)))
            }
            current = parent
        }
        return segments.reversed()
    }

    /// Position of a child among its parent's children (child indices ascend, so this is a binary search).
    private func position(of child: Int, in parent: Int) -> Int {
        let children = nodes[parent].children
        var low = 0, high = children.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if children[mid] == child { return mid }
            if children[mid] < child { low = mid + 1 } else { high = mid - 1 }
        }
        return 0
    }
}
