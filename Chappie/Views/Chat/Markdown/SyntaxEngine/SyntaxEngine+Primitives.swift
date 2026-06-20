// SyntaxEngine+Primitives.swift
// Chappie

import AppKit

// MARK: - Low-level coloring primitives

extension SyntaxEngine {

    // unichar constants — avoids magic numbers in coloring primitives
    static let uniUnderscore:  unichar = 95
    static let uniAt:          unichar = 64
    static let uniHash:        unichar = 35
    static let uni0:           unichar = 48
    static let uni9:           unichar = 57
    static let uniA_upper:     unichar = 65
    static let uniZ_upper:     unichar = 90
    static let uniA_lower:     unichar = 97
    static let uniZ_lower:     unichar = 122
    static let uniDoubleQuote: unichar = 34
    static let uniSingleQuote: unichar = 39
    static let uniBackslash:   unichar = 92
    static let uniNewline:     unichar = 10
    static let uniDollar:      unichar = 36
    static let uniOpenBrace:   unichar = 123
    static let uniCloseBrace:  unichar = 125
    static let uniDot:         unichar = 46
    static let uniX_lower:     unichar = 120
    static let uniB_lower:     unichar = 98
    static let uniF_lower:     unichar = 102
    static let uniF_upper:     unichar = 70
    static let uniColon:       unichar = 58

    /// Returns true if a UTF-16 code unit is a word character (letter, digit, _, @, #).
    static func isWord(_ c: unichar) -> Bool {
        if c == uniUnderscore || c == uniAt || c == uniHash { return true }
        if c >= uni0 && c <= uni9 { return true }
        if c >= uniA_upper && c <= uniZ_upper { return true }
        if c >= uniA_lower && c <= uniZ_lower { return true }
        if c > 127 { return true } // Unicode letters (Cyrillic etc.)
        return false
    }

    /// Applies NSColor to all word-boundary occurrences of a keyword.
    static func colorWord(
        _ color: NSColor, word: String, in str: NSMutableAttributedString, ci: Bool = false
    ) {
        let text = str.string
        let options: NSString.CompareOptions = ci ? [.literal, .caseInsensitive] : [.literal]
        var searchRange = NSRange(location: 0, length: text.utf16.count)

        while searchRange.length > 0 {
            let found = (text as NSString).range(of: word, options: options, range: searchRange)
            guard found.location != NSNotFound else { break }
            let ns = text as NSString
            let leftOk  = found.location == 0 || !isWord(ns.character(at: found.location - 1))
            let endLoc  = found.location + found.length
            let rightOk = endLoc >= ns.length || !isWord(ns.character(at: endLoc))
            if leftOk && rightOk { str.addAttribute(.foregroundColor, value: color, range: found) }
            let next = found.location + found.length
            searchRange = NSRange(location: next, length: text.utf16.count - next)
        }
    }

    /// Highlights PascalCase words as type names.
    /// Only called for languages where PascalCase = type convention (Swift, Kotlin, etc.)
    static func colorTypes(_ color: NSColor, in str: NSMutableAttributedString) {
        let ns = str.string as NSString
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            guard c >= uniA_upper && c <= uniZ_upper else { i += 1; continue }
            var j = i + 1
            while j < ns.length && isWord(ns.character(at: j)) { j += 1 }
            if j - i > 1 { str.addAttribute(.foregroundColor, value: color, range: NSRange(location: i, length: j - i)) }
            i = j
        }
    }

    /// Highlights string literals in double and single quotes.
    static func colorStrings(_ color: NSColor, in str: NSMutableAttributedString) {
        for q: unichar in [uniDoubleQuote, uniSingleQuote] {
            let ns = str.string as NSString
            var i = 0; var inStr = false; var start = 0
            while i < ns.length {
                let c = ns.character(at: i)
                if c == q && !inStr         { inStr = true; start = i }
                else if c == q && inStr     { inStr = false; str.addAttribute(.foregroundColor, value: color, range: NSRange(location: start, length: i - start + 1)) }
                else if c == uniBackslash && inStr { i += 1; if i >= ns.length { break } }
                else if c == uniNewline && inStr   { inStr = false }
                i += 1
            }
        }
    }

    /// Highlights numeric literals (decimal, hex, binary, float).
    static func colorNumbers(_ color: NSColor, in str: NSMutableAttributedString) {
        let ns = str.string as NSString
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            guard c >= uni0 && c <= uni9 else { i += 1; continue }
            // Skip digits that are part of an identifier (e.g. "var2")
            if i > 0 && isWord(ns.character(at: i - 1)) { i += 1; continue }
            var j = i
            while j < ns.length {
                let ch = ns.character(at: j)
                let ok = (ch >= uni0 && ch <= uni9)
                    || ch == uniDot || ch == uniUnderscore
                    || ch == uniX_lower || ch == uniB_lower
                    || (ch >= uniA_lower && ch <= uniF_lower)
                    || (ch >= uniA_upper && ch <= uniF_upper)
                if !ok { break }
                j += 1
            }
            str.addAttribute(.foregroundColor, value: color, range: NSRange(location: i, length: j - i))
            i = j
        }
    }

    /// Highlights single-line comments from prefix to end of line.
    static func colorComments(_ prefix: String, color: NSColor, in str: NSMutableAttributedString) {
        let ns = str.string as NSString
        let pLen = prefix.utf16.count
        var i = 0
        while i < ns.length {
            if i + pLen <= ns.length,
               ns.substring(with: NSRange(location: i, length: pLen)) == prefix {
                var j = i
                while j < ns.length && ns.character(at: j) != uniNewline { j += 1 }
                str.addAttribute(.foregroundColor, value: color, range: NSRange(location: i, length: j - i))
                i = j + 1
            } else {
                i += 1
            }
        }
    }

    /// Highlights $VAR and ${VAR} bash variable references.
    static func colorBashVars(_ color: NSColor, in str: NSMutableAttributedString) {
        let ns = str.string as NSString
        var i = 0
        while i < ns.length {
            guard ns.character(at: i) == uniDollar else { i += 1; continue }
            let start = i; i += 1
            guard i < ns.length else { break }
            if ns.character(at: i) == uniOpenBrace {
                i += 1
                while i < ns.length && ns.character(at: i) != uniCloseBrace { i += 1 }
                if i < ns.length { i += 1; str.addAttribute(.foregroundColor, value: color, range: NSRange(location: start, length: i - start)) }
            } else {
                while i < ns.length && isWord(ns.character(at: i)) { i += 1 }
                if i > start + 1 { str.addAttribute(.foregroundColor, value: color, range: NSRange(location: start, length: i - start)) }
            }
        }
    }

    /// Highlights JSON strings, distinguishing keys (before ':') from values.
    ///
    /// JSON key: a quoted string immediately followed (after optional whitespace) by ':'.
    /// JSON value: any other quoted string.
    static func colorJsonStrings(
        keyColor: NSColor, valueColor: NSColor, in str: NSMutableAttributedString
    ) {
        let ns = str.string as NSString
        var i = 0
        while i < ns.length {
            guard ns.character(at: i) == uniDoubleQuote else { i += 1; continue }
            let start = i; i += 1
            // Scan to closing quote, respecting backslash escapes
            while i < ns.length {
                let c = ns.character(at: i)
                if c == uniBackslash { i += 2; continue }
                if c == uniDoubleQuote { i += 1; break }
                i += 1
            }
            let strRange = NSRange(location: start, length: i - start)
            // Look ahead for ':' to determine if this is a key
            var j = i
            while j < ns.length && (ns.character(at: j) == 32 || ns.character(at: j) == 9) { j += 1 }
            let isKey = j < ns.length && ns.character(at: j) == uniColon
            str.addAttribute(.foregroundColor, value: isKey ? keyColor : valueColor, range: strRange)
        }
    }
}
