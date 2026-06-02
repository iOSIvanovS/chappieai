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
    /// NSCache is thread-safe and auto-evicts under memory pressure.
    private static let cache = NSCache<NSString, NSAttributedString>()

    // Exposed so CodeBlockView can resolve the theme before highlighting.
    static func normalizePublic(_ language: String?) -> String { normalize(language) }

    static func highlight(code: String, language: String?, theme: SyntaxNSTheme) -> NSAttributedString {
        let lang = normalize(language)
        // Use theme's plainText color pointer as a cheap dark/light discriminator.
        // NSColor instances from SyntaxNSTheme are static — pointer equality is stable.
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

    private static func normalize(_ language: String?) -> String {
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

    private enum CommentStyle { case slashSlash, hash, doubleDash }

    // MARK: - Plain text fallback

    private static func plain(_ code: String, theme: SyntaxNSTheme) -> NSAttributedString {
        let result = NSMutableAttributedString(string: code)
        let r = NSRange(location: 0, length: result.length)
        result.addAttribute(.foregroundColor, value: theme.plainText, range: r)
        result.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular), range: r)
        return result
    }

    // MARK: - Generic keyword highlighter

    private static func kw(
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

    private static func bash(_ code: String, theme: SyntaxNSTheme) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let result = NSMutableAttributedString(string: code)
        let full = NSRange(location: 0, length: result.length)
        result.addAttribute(.foregroundColor, value: theme.plainText, range: full)
        result.addAttribute(.font, value: font, range: full)
        for kw in bashKeywords { colorWord(theme.keyword, word: kw, in: result) }
        colorBashVars(theme.variable, in: result)  // $VAR in variable color (green)
        colorStrings(theme.string, in: result)
        colorNumbers(theme.number, in: result)
        colorComments("#", color: theme.comment, in: result)
        return result
    }

    // MARK: - JSON

    /// JSON gets special treatment: keys and string values are colored differently.
    /// Keys (before ':') get jsonKey color (blue), values get string color (orange).
    private static func json(_ code: String, theme: SyntaxNSTheme) -> NSAttributedString {
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

    // MARK: - Keyword tables

    private static let swiftKeywords: [String] = [
        "func", "var", "let", "class", "struct", "enum", "protocol",
        "extension", "import", "return", "if", "else", "guard", "switch",
        "case", "default", "for", "while", "do", "try", "catch", "throw",
        "throws", "async", "await", "actor", "nonisolated", "isolated",
        "public", "private", "internal", "fileprivate", "open",
        "static", "final", "override", "mutating", "nonmutating",
        "init", "deinit", "self", "super", "nil", "true", "false",
        "in", "is", "as", "where", "some", "any", "typealias",
        "@MainActor", "@Observable", "@State", "@Binding", "@Environment",
        "@Published", "@StateObject", "@ObservedObject", "Task", "MainActor"
    ]
    private static let pythonKeywords: [String] = [
        "def", "class", "import", "from", "as", "return", "if", "elif", "else",
        "for", "while", "try", "except", "finally", "raise", "with", "pass",
        "break", "continue", "lambda", "yield", "global", "nonlocal", "del",
        "assert", "and", "or", "not", "in", "is", "None", "True", "False",
        "async", "await", "self", "cls"
    ]
    private static let pythonBuiltins: [String] = [
        "print", "len", "range", "type", "isinstance", "int", "str", "float",
        "bool", "list", "dict", "set", "tuple", "enumerate", "zip", "map",
        "filter", "sorted", "reversed", "sum", "min", "max", "abs", "round",
        "open", "input", "super", "property", "staticmethod", "classmethod",
        "hasattr", "getattr", "setattr", "delattr", "vars", "dir", "repr",
        "format", "chr", "ord", "hex", "bin", "oct", "id", "hash",
        "__init__", "__name__", "__main__", "__str__", "__repr__"
    ]
    private static let jsKeywords: [String] = [
        "function", "const", "let", "var", "class", "extends", "import", "export",
        "default", "return", "if", "else", "for", "while", "do", "try", "catch",
        "finally", "throw", "new", "this", "super", "typeof", "instanceof",
        "switch", "case", "break", "continue", "of", "in", "from", "async",
        "await", "null", "undefined", "true", "false", "static", "get", "set",
        "delete", "void", "yield"
    ]
    private static let jsBuiltins: [String] = [
        "console", "Promise", "Array", "Object", "String", "Number", "Boolean",
        "Math", "Date", "JSON", "Error", "Map", "Set", "WeakMap", "WeakSet",
        "Symbol", "Proxy", "Reflect", "fetch", "setTimeout", "setInterval",
        "clearTimeout", "clearInterval", "parseInt", "parseFloat", "isNaN",
        "isFinite", "encodeURIComponent", "decodeURIComponent",
        "document", "window", "navigator", "location", "history",
        "localStorage", "sessionStorage", "XMLHttpRequest", "WebSocket",
        "process", "Buffer", "require", "module", "exports", "__dirname"
    ]
    private static let tsKeywords: [String] = jsKeywords + [
        "interface", "type", "enum", "namespace", "declare", "abstract",
        "readonly", "private", "public", "protected", "implements",
        "keyof", "never", "unknown", "any", "infer"
    ]
    private static let kotlinKeywords: [String] = [
        "fun", "val", "var", "class", "object", "interface", "enum", "sealed",
        "data", "abstract", "open", "final", "override", "private", "public",
        "protected", "internal", "companion", "import", "package", "return",
        "if", "else", "when", "for", "while", "do", "try", "catch", "finally",
        "throw", "throws", "is", "as", "in", "out", "by", "init", "constructor",
        "this", "super", "null", "true", "false", "suspend", "inline", "reified",
        "typealias", "lateinit", "lazy", "it", "apply", "let", "run", "also", "with"
    ]
    private static let rustKeywords: [String] = [
        "fn", "let", "mut", "const", "static", "struct", "enum", "trait",
        "impl", "use", "mod", "pub", "crate", "self", "super", "type",
        "where", "for", "while", "loop", "if", "else", "match", "return",
        "break", "continue", "in", "as", "ref", "move", "box", "dyn",
        "async", "await", "unsafe", "extern", "true", "false", "None", "Some",
        "Ok", "Err", "Vec", "String", "Option", "Result", "Box", "Rc", "Arc"
    ]
    private static let goKeywords: [String] = [
        "func", "var", "const", "type", "struct", "interface", "map", "chan",
        "package", "import", "return", "if", "else", "for", "range", "switch",
        "case", "default", "break", "continue", "goto", "fallthrough",
        "go", "select", "defer", "nil", "true", "false",
        "int", "int8", "int16", "int32", "int64",
        "uint", "uint8", "uint16", "uint32", "uint64",
        "float32", "float64", "complex64", "complex128",
        "string", "bool", "byte", "rune", "error", "any"
    ]
    private static let goBuiltins: [String] = [
        "make", "new", "len", "cap", "append", "copy", "delete",
        "close", "panic", "recover", "print", "println"
    ]
    private static let javaKeywords: [String] = [
        "public", "private", "protected", "static", "final", "abstract",
        "class", "interface", "enum", "extends", "implements", "import",
        "package", "return", "if", "else", "for", "while", "do", "try",
        "catch", "finally", "throw", "throws", "new", "this", "super",
        "instanceof", "switch", "case", "default", "break", "continue",
        "void", "int", "long", "double", "float", "boolean", "char",
        "byte", "short", "null", "true", "false", "synchronized",
        "volatile", "transient", "native", "strictfp", "assert"
    ]
    private static let cKeywords: [String] = [
        "int", "long", "short", "char", "float", "double", "void",
        "unsigned", "signed", "const", "static", "extern", "register",
        "volatile", "auto", "inline", "restrict",
        "if", "else", "for", "while", "do", "switch", "case", "default",
        "break", "continue", "return", "goto",
        "struct", "union", "enum", "typedef",
        "sizeof", "NULL", "true", "false",
        "#include", "#define", "#ifdef", "#ifndef", "#endif", "#pragma"
    ]
    private static let bashKeywords: [String] = [
        "echo", "export", "source", "cd", "ls", "mkdir", "rm", "mv", "cp",
        "cat", "grep", "sed", "awk", "find", "chmod", "chown", "sudo",
        "if", "then", "else", "elif", "fi", "for", "while", "do", "done",
        "case", "esac", "in", "function", "return", "exit", "local",
        "read", "set", "unset", "shift", "trap", "exec", "eval",
        "true", "false", "test", "kill", "sleep", "printf", "pwd"
    ]
    private static let sqlKeywords: [String] = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "EXISTS",
        "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
        "CREATE", "TABLE", "ALTER", "DROP", "INDEX", "VIEW",
        "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "ON",
        "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET",
        "AS", "DISTINCT", "ALL", "UNION", "INTERSECT", "EXCEPT",
        "NULL", "IS", "LIKE", "BETWEEN", "CASE", "WHEN", "THEN", "ELSE", "END",
        "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "DEFAULT",
        "NOT NULL", "AUTO_INCREMENT", "SERIAL", "RETURNING",
        "BEGIN", "COMMIT", "ROLLBACK", "TRANSACTION",
        "INT", "INTEGER", "VARCHAR", "TEXT", "BOOLEAN", "DATE", "TIMESTAMP", "FLOAT", "NUMERIC"
    ]
    private static let sqlBuiltins: [String] = [
        "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "NULLIF", "CAST",
        "UPPER", "LOWER", "TRIM", "LENGTH", "SUBSTRING", "REPLACE",
        "NOW", "CURRENT_DATE", "CURRENT_TIMESTAMP", "EXTRACT",
        "ROW_NUMBER", "RANK", "DENSE_RANK", "OVER", "PARTITION",
        "CONCAT", "ROUND", "FLOOR", "CEIL", "ABS", "MOD", "POWER"
    ]

    // MARK: - Coloring primitives (NSRange + unichar — no unicode index issues)

    /// Returns true if a UTF-16 code unit is a word character (letter, digit, _, @, #).
    private static func isWord(_ c: unichar) -> Bool {
        if c == uniUnderscore || c == uniAt || c == uniHash { return true }
        if c >= uni0 && c <= uni9 { return true }
        if c >= uniA_upper && c <= uniZ_upper { return true }
        if c >= uniA_lower && c <= uniZ_lower { return true }
        if c > 127 { return true } // Unicode letters (Cyrillic etc.)
        return false
    }

    /// Applies NSColor to all word-boundary occurrences of a keyword.
    private static func colorWord(
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
    private static func colorTypes(_ color: NSColor, in str: NSMutableAttributedString) {
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
    private static func colorStrings(_ color: NSColor, in str: NSMutableAttributedString) {
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

    /// Highlights numeric literals.
    private static func colorNumbers(_ color: NSColor, in str: NSMutableAttributedString) {
        let ns = str.string as NSString
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            guard c >= uni0 && c <= uni9 else { i += 1; continue }
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
    private static func colorComments(_ prefix: String, color: NSColor, in str: NSMutableAttributedString) {
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
    private static func colorBashVars(_ color: NSColor, in str: NSMutableAttributedString) {
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
    /// This gives keys a distinct color (blue) vs string values (orange).
    private static func colorJsonStrings(
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
