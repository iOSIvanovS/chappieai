// SyntaxEngine.swift
// Chappie

import AppKit

// MARK: - Syntax engine (NSAttributedString-based)

/// Produces NSAttributedString with syntax coloring for 11 languages.
///
/// All coloring uses NSColor via NSRange — reliable in NSTextView,
/// no SwiftUI attribute scope issues, no unicode index mismatches.
///
/// PER-LANGUAGE RULES:
/// - colorTypes (PascalCase) only for: swift, kotlin, rust, go, java, cpp/c
/// - colorBuiltins only for: python, javascript, typescript, sql, bash
/// - colorJsonKeys only for: json
/// - colorBashVars only for: bash
///
/// CACHE (CPU-03):
/// NSCache keyed by "\(code.hashValue)_\(language)_\(dark)" — avoids re-highlighting
/// the same code block on every SwiftUI re-render. NSCache is thread-safe and
/// automatically evicts under memory pressure.
enum SyntaxEngine {

    // MARK: - Cache

    /// Global highlight cache. Key: "hashValue_language_dark".
    private static let cache = NSCache<NSString, NSAttributedString>()

    // Exposed so CodeBlockView can resolve the theme before highlighting.
    static func normalizePublic(_ language: String?) -> String { normalize(language) }

    static func highlight(code: String, language: String?, theme: SyntaxNSTheme) -> NSAttributedString {
        let lang = normalize(language)
        // Use theme's plainText color pointer as a cheap dark/light discriminator.
        let isDark = theme.plainText != NSColor.black
        let key = "\(code.hashValue)_\(lang)_\(isDark)" as NSString

        if let cached = cache.object(forKey: key) { return cached }

        let result: NSAttributedString
        switch lang {
        case "swift":
            result = kw(code, keywords: swiftKeywords, types: true, builtins: [],
                        comment: .slashSlash, theme: theme)
        case "python":
            result = kw(code, keywords: pythonKeywords, types: false, builtins: pythonBuiltins,
                        comment: .hash, theme: theme)
        case "javascript":
            result = kw(code, keywords: jsKeywords, types: false, builtins: jsBuiltins,
                        comment: .slashSlash, theme: theme)
        case "typescript":
            result = kw(code, keywords: tsKeywords, types: true, builtins: jsBuiltins,
                        comment: .slashSlash, theme: theme)
        case "kotlin":
            result = kw(code, keywords: kotlinKeywords, types: true, builtins: [],
                        comment: .slashSlash, theme: theme)
        case "rust":
            result = kw(code, keywords: rustKeywords, types: true, builtins: [],
                        comment: .slashSlash, theme: theme)
        case "go":
            result = kw(code, keywords: goKeywords, types: true, builtins: goBuiltins,
                        comment: .slashSlash, theme: theme)
        case "java":
            result = kw(code, keywords: javaKeywords, types: true, builtins: [],
                        comment: .slashSlash, theme: theme)
        case "c", "cpp":
            result = kw(code, keywords: cKeywords, types: false, builtins: [],
                        comment: .slashSlash, theme: theme)
        case "bash":
            result = bash(code, theme: theme)
        case "json":
            result = json(code, theme: theme)
        case "sql":
            result = kw(code, keywords: sqlKeywords, types: false, builtins: sqlBuiltins,
                        comment: .doubleDash, theme: theme, caseInsensitive: true)
        default:
            result = plain(code, theme: theme)
        }

        cache.setObject(result, forKey: key)
        return result
    }

    // MARK: - Language normalization

    static func normalize(_ language: String?) -> String {
        switch language?.lowercased() ?? "" {
        case "js", "javascript":    return "javascript"
        case "ts", "typescript":    return "typescript"
        case "sh", "shell", "bash": return "bash"
        case "cpp", "c++":          return "cpp"
        case "swift":               return "swift"
        case "python", "py":        return "python"
        case "kotlin", "kt":        return "kotlin"
        case "rust", "rs":          return "rust"
        case "go", "golang":        return "go"
        case "java":                return "java"
        case "json":                return "json"
        case "sql":                 return "sql"
        case "c":                   return "c"
        default:                    return language?.lowercased() ?? ""
        }
    }

    // MARK: - Comment styles

    enum CommentStyle { case slashSlash, hash, doubleDash }

    // MARK: - Plain text fallback

    static func plain(_ code: String, theme: SyntaxNSTheme) -> NSAttributedString {
        let result = NSMutableAttributedString(string: code)
        let r = NSRange(location: 0, length: result.length)
        result.addAttribute(.foregroundColor, value: theme.plainText, range: r)
        result.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular), range: r)
        return result
    }

    // MARK: - Generic keyword highlighter

    static func kw(
        _ code: String,
        keywords: [String],
        types: Bool,
        builtins: [String],
        comment: CommentStyle,
        theme: SyntaxNSTheme,
        caseInsensitive: Bool = false
    ) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let result = NSMutableAttributedString(string: code)
        let full = NSRange(location: 0, length: result.length)
        result.addAttribute(.foregroundColor, value: theme.plainText, range: full)
        result.addAttribute(.font, value: font, range: full)

        // Order matters: keywords first, then types (PascalCase), then builtins on top.
        // Strings and numbers go after — they override everything inside string literals.
        for kw in keywords { colorWord(theme.keyword, word: kw, in: result, ci: caseInsensitive) }
        if types { colorTypes(theme.type_, in: result) }
        for b in builtins { colorWord(theme.builtin, word: b, in: result) }
        colorStrings(theme.string, in: result)
        colorNumbers(theme.number, in: result)
        switch comment {
        case .slashSlash: colorComments("//", color: theme.comment, in: result)
        case .hash:       colorComments("#",  color: theme.comment, in: result)
        case .doubleDash: colorComments("--", color: theme.comment, in: result)
        }
        return result
    }

    // MARK: - Bash

    static func bash(_ code: String, theme: SyntaxNSTheme) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let result = NSMutableAttributedString(string: code)
        let full = NSRange(location: 0, length: result.length)
        result.addAttribute(.foregroundColor, value: theme.plainText, range: full)
        result.addAttribute(.font, value: font, range: full)
        for kw in bashKeywords { colorWord(theme.keyword, word: kw, in: result) }
        colorBashVars(theme.variable, in: result)
        colorStrings(theme.string, in: result)
        colorNumbers(theme.number, in: result)
        colorComments("#", color: theme.comment, in: result)
        return result
    }

    // MARK: - JSON

    /// JSON gets special treatment: keys and string values are colored differently.
    static func json(_ code: String, theme: SyntaxNSTheme) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let result = NSMutableAttributedString(string: code)
        let full = NSRange(location: 0, length: result.length)
        result.addAttribute(.foregroundColor, value: theme.plainText, range: full)
        result.addAttribute(.font, value: font, range: full)
        for kw in ["true", "false", "null"] { colorWord(theme.keyword, word: kw, in: result) }
        colorNumbers(theme.number, in: result)
        colorJsonStrings(keyColor: theme.jsonKey, valueColor: theme.string, in: result)
        return result
    }
}
