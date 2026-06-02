// MarkdownModels.swift
// Chappie

import Foundation

// MARK: - ASCII unichar constants
// Swift has no UInt16(ascii:) initializer. These constants replace all literal
// comparisons to avoid magic numbers and keep the code readable.
let uniUnderscore:  unichar = 95   // _
let uniAt:          unichar = 64   // @
let uniHash:        unichar = 35   // #
let uniDollar:      unichar = 36   // $
let uniOpenBrace:   unichar = 123  // {
let uniCloseBrace:  unichar = 125  // }
let uniBackslash:   unichar = 92   // \
let uniNewline:     unichar = 10   // \n
let uniDoubleQuote: unichar = 34   // "
let uniSingleQuote: unichar = 39   // '
let uni0:           unichar = 48   // 0
let uni9:           unichar = 57   // 9
let uniA_upper:     unichar = 65   // A
let uniZ_upper:     unichar = 90   // Z
let uniA_lower:     unichar = 97   // a
let uniZ_lower:     unichar = 122  // z
let uniF_lower:     unichar = 102  // f
let uniF_upper:     unichar = 70   // F
let uniDot:         unichar = 46   // .
let uniX_lower:     unichar = 120  // x
let uniB_lower:     unichar = 98   // b
let uniColon:       unichar = 58   // :

// MARK: - Block model

/// Structural unit of parsed markdown text.
///
/// STABLE IDs: use positional index — prevents SwiftUI view identity collisions
/// when multiple blocks have similar content prefixes.
enum MarkdownBlock: Identifiable {
    case paragraph(String, index: Int)
    case heading(String, level: Int, index: Int)
    case codeBlock(code: String, language: String?, index: Int)
    case divider(index: Int)
    case table(headers: [String], rows: [[String]], index: Int)

    var id: String {
        switch self {
        case .paragraph(_, let i):        return "p_\(i)"
        case .heading(_, _, let i):       return "h_\(i)"
        case .codeBlock(_, _, let i):     return "code_\(i)"
        case .divider(let i):             return "div_\(i)"
        case .table(_, _, let i):         return "table_\(i)"
        }
    }
}

// MARK: - Markdown parser

struct MarkdownParser {

    // MARK: - Cache (CPU-02)

    /// Parsed block cache keyed by text hash.
    /// Prevents re-parsing the same message on every SwiftUI re-render.
    /// NSCache is thread-safe and auto-evicts under memory pressure.
    ///
    /// WHY NSCache<NSString, NSArray>: [MarkdownBlock] is not an NSObject,
    /// so we box it in a thin wrapper to store in NSCache.
    private static let cache = NSCache<NSString, ParsedBlocksBox>()

    static func parse(_ text: String) -> [MarkdownBlock] {
        let key = "\(text.hashValue)" as NSString
        if let cached = cache.object(forKey: key) { return cached.blocks }
        let result = _parse(text)
        cache.setObject(ParsedBlocksBox(result), forKey: key)
        return result
    }

    // MARK: - Core parser (called once per unique text)

    private static func _parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var blockIndex = 0

        while i < lines.count {
            let line = lines[i]

            // Code block: ```lang
            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 }
                let code = codeLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
                blocks.append(.codeBlock(code: code, language: lang.isEmpty ? nil : lang, index: blockIndex))
                blockIndex += 1
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Horizontal divider
            if trimmed == "---" || trimmed == "***" {
                blocks.append(.divider(index: blockIndex)); blockIndex += 1; i += 1; continue
            }

            // Headings
            if line.hasPrefix("### ") {
                blocks.append(.heading(String(line.dropFirst(4)), level: 3, index: blockIndex))
                blockIndex += 1; i += 1; continue
            }
            if line.hasPrefix("## ") {
                blocks.append(.heading(String(line.dropFirst(3)), level: 2, index: blockIndex))
                blockIndex += 1; i += 1; continue
            }
            if line.hasPrefix("# ") {
                blocks.append(.heading(String(line.dropFirst(2)), level: 1, index: blockIndex))
                blockIndex += 1; i += 1; continue
            }

            // Table
            if trimmed.hasPrefix("|") {
                var tableLines: [String] = [line]
                i += 1
                while i < lines.count {
                    let nt = lines[i].trimmingCharacters(in: .whitespaces)
                    if nt.hasPrefix("|") { tableLines.append(lines[i]); i += 1 } else { break }
                }
                if let tb = parseTable(tableLines, index: blockIndex) {
                    blocks.append(tb); blockIndex += 1
                } else {
                    for tl in tableLines {
                        let tlt = tl.trimmingCharacters(in: .whitespaces)
                        if !tlt.isEmpty { blocks.append(.paragraph(tl, index: blockIndex)); blockIndex += 1 }
                    }
                }
                continue
            }

            // Empty line
            if trimmed.isEmpty { i += 1; continue }

            // Plain paragraph
            var paragraphLines: [String] = [line]
            i += 1
            while i < lines.count {
                let next = lines[i]
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty || next.hasPrefix("```")
                    || next.hasPrefix("# ") || next.hasPrefix("## ") || next.hasPrefix("### ")
                    || nextTrimmed == "---" || nextTrimmed.hasPrefix("|") { break }
                paragraphLines.append(next); i += 1
            }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n"), index: blockIndex))
            blockIndex += 1
        }
        return blocks
    }

    private static func parseTable(_ lines: [String], index: Int) -> MarkdownBlock? {
        guard lines.count >= 2 else { return nil }
        func parseCells(_ line: String) -> [String] {
            var cells = line.components(separatedBy: "|")
            if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
            if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
            return cells.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let sep = lines[1].trimmingCharacters(in: .whitespaces)
        guard sep.allSatisfy({ $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }) else { return nil }
        let headers = parseCells(lines[0])
        guard !headers.isEmpty else { return nil }
        let rows = lines.dropFirst(2).map { parseCells($0) }
        return .table(headers: headers, rows: rows, index: index)
    }
}

// MARK: - NSCache box

/// Thin NSObject wrapper so [MarkdownBlock] can be stored in NSCache.
private final class ParsedBlocksBox: NSObject {
    let blocks: [MarkdownBlock]
    init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
}
