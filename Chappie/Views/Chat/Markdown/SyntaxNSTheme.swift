// SyntaxNSTheme.swift
// Chappie

import AppKit

// MARK: - Syntax color themes (NSColor-based)

/// Color palette for syntax highlighting using NSColor.
///
/// WHY NSColor INSTEAD OF SwiftUI Color:
/// NSAttributedString used by NSTextView requires NSColor for .foregroundColor attribute.
/// SwiftUI Color in AttributedString is unreliable inside ScrollView on macOS —
/// the color gets silently dropped. NSColor + NSTextView = always correct rendering.
///
/// PER-LANGUAGE THEMES:
/// Each language family has its own color identity. SyntaxNSTheme.forLanguage()
/// selects the right theme. This gives each language its native IDE feel:
/// - Swift/Kotlin/Rust/Go: Xcode-style
/// - Python: VSCode Python-style
/// - JS/TS: VSCode JS-style
/// - Bash: terminal green style
/// - SQL: classic SQL blue style
/// - JSON: data-viewer style (keys vs values distinguished)
/// - C/C++/Java: classic blue-keyword style
struct SyntaxNSTheme {

    let background: NSColor
    let plainText:  NSColor
    let keyword:    NSColor   // language keywords (if, for, func, def...)
    let type_:      NSColor   // PascalCase types — only for languages with explicit types
    let string:     NSColor   // string literals
    let number:     NSColor   // numeric literals
    let comment:    NSColor   // comments
    let builtin:    NSColor   // built-in functions / special identifiers
    let variable:   NSColor   // variables, parameters, $vars (bash)
    let jsonKey:    NSColor   // JSON object keys (separate from string values)

    // MARK: - Swift / Kotlin / Rust / Go — Xcode Default Dark
    static let xcodeDefaultDark = SyntaxNSTheme(
        background: NSColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1), // #1E1E1E
        plainText:  NSColor(red: 0.970, green: 0.970, blue: 0.950, alpha: 1), // #F7F7F2
        keyword:    NSColor(red: 0.988, green: 0.373, blue: 0.639, alpha: 1), // #FC5FA3 pink
        type_:      NSColor(red: 0.365, green: 0.847, blue: 1.000, alpha: 1), // #5DD8FF light blue
        string:     NSColor(red: 0.988, green: 0.416, blue: 0.365, alpha: 1), // #FC6A5D red-orange
        number:     NSColor(red: 0.816, green: 0.749, blue: 0.412, alpha: 1), // #D0BF69 gold
        comment:    NSColor(red: 0.424, green: 0.475, blue: 0.525, alpha: 1), // #6C7986 gray
        builtin:    NSColor(red: 0.365, green: 0.847, blue: 1.000, alpha: 1), // same as type_ for Swift
        variable:   NSColor(red: 0.970, green: 0.970, blue: 0.950, alpha: 1), // plain
        jsonKey:    NSColor(red: 0.365, green: 0.847, blue: 1.000, alpha: 1)  // unused here
    )

    // MARK: - Swift / Kotlin / Rust / Go — Xcode Default Light
    static let xcodeDefaultLight = SyntaxNSTheme(
        background: NSColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1), // #FFFFFF
        plainText:  NSColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1), // #000000
        keyword:    NSColor(red: 0.659, green: 0.055, blue: 0.565, alpha: 1), // #A80E90 purple
        type_:      NSColor(red: 0.110, green: 0.384, blue: 0.655, alpha: 1), // #1C6278 dark blue
        string:     NSColor(red: 0.773, green: 0.102, blue: 0.086, alpha: 1), // #C51A16 dark red
        number:     NSColor(red: 0.118, green: 0.400, blue: 0.188, alpha: 1), // #1E6630 dark green
        comment:    NSColor(red: 0.408, green: 0.435, blue: 0.459, alpha: 1), // #686F75 gray
        builtin:    NSColor(red: 0.110, green: 0.384, blue: 0.655, alpha: 1), // same as type_
        variable:   NSColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1), // plain
        jsonKey:    NSColor(red: 0.110, green: 0.384, blue: 0.655, alpha: 1)  // unused here
    )

    // MARK: - Python — VSCode Python Dark
    // Keywords: orange, builtins (print/len/range): yellow-green, strings: yellow, types: none
    static let pythonDark = SyntaxNSTheme(
        background: NSColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1),
        plainText:  NSColor(red: 0.970, green: 0.970, blue: 0.950, alpha: 1),
        keyword:    NSColor(red: 0.863, green: 0.502, blue: 0.188, alpha: 1), // #DC8130 orange
        type_:      NSColor(red: 0.970, green: 0.970, blue: 0.950, alpha: 1), // plain (no PascalCase coloring)
        string:     NSColor(red: 0.878, green: 0.820, blue: 0.494, alpha: 1), // #E0D17E yellow
        number:     NSColor(red: 0.682, green: 0.855, blue: 0.620, alpha: 1), // #AEDB9E light green
        comment:    NSColor(red: 0.424, green: 0.475, blue: 0.525, alpha: 1), // gray
        builtin:    NSColor(red: 0.365, green: 0.847, blue: 1.000, alpha: 1), // #5DD8FF cyan (print, len, range...)
        variable:   NSColor(red: 0.970, green: 0.970, blue: 0.950, alpha: 1), // plain
        jsonKey:    NSColor(red: 0.365, green: 0.847, blue: 1.000, alpha: 1)
    )

    // MARK: - Python — VSCode Python Light
    static let pythonLight = SyntaxNSTheme(
        background: NSColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1),
        plainText:  NSColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1),
        keyword:    NSColor(red: 0.000, green: 0.000, blue: 0.800, alpha: 1), // #0000CC blue
        type_:      NSColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1), // plain
        string:     NSColor(red: 0.647, green: 0.161, blue: 0.161, alpha: 1), // #A52929 dark red
        number:     NSColor(red: 0.063, green: 0.502, blue: 0.063, alpha: 1), // #108010 dark green
        comment:    NSColor(red: 0.408, green: 0.435, blue: 0.459, alpha: 1),
        builtin:    NSColor(red: 0.502, green: 0.000, blue: 0.502, alpha: 1), // #800080 purple
        variable:   NSColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1),
        jsonKey:    NSColor(red: 0.502, green: 0.000, blue: 0.502, alpha: 1)
    )

    // MARK: - JavaScript / TypeScript — VSCode Dark
    // Keywords: blue, functions/builtins: yellow, strings: green, numbers: light green
    static let jsDark = SyntaxNSTheme(
        background: NSColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1),
        plainText:  NSColor(red: 0.970, green: 0.970, blue: 0.950, alpha: 1),
        keyword:    NSColor(red: 0.337, green: 0.612, blue: 0.878, alpha: 1), // #569CD6 blue
        type_:      NSColor(red: 0.267, green: 0.788, blue: 0.733, alpha: 1), // #44C9BB teal (TS types)
        string:     NSColor(red: 0.565, green: 0.773, blue: 0.502, alpha: 1), // #90C580 green
        number:     NSColor(red: 0.682, green: 0.855, blue: 0.620, alpha: 1), // #AEDB9E light green
        comment:    NSColor(red: 0.424, green: 0.475, blue: 0.525, alpha: 1),
        builtin:    NSColor(red: 0.867, green: 0.812, blue: 0.247, alpha: 1), // #DDCF3F yellow (console, Promise...)
        variable:   NSColor(red: 0.608, green: 0.827, blue: 0.969, alpha: 1), // #9BD3F7 light blue
        jsonKey:    NSColor(red: 0.337, green: 0.612, blue: 0.878, alpha: 1)
    )

    // MARK: - JavaScript / TypeScript — VSCode Light
    static let jsLight = SyntaxNSTheme(
        background: NSColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1),
        plainText:  NSColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1),
        keyword:    NSColor(red: 0.000, green: 0.000, blue: 0.800, alpha: 1), // #0000CC blue
        type_:      NSColor(red: 0.063, green: 0.502, blue: 0.502, alpha: 1), // #107F7F teal
        string:     NSColor(red: 0.647, green: 0.161, blue: 0.161, alpha: 1), // #A52929 dark red
        number:     NSColor(red: 0.063, green: 0.502, blue: 0.063, alpha: 1), // #108010 dark green
        comment:    NSColor(red: 0.408, green: 0.435, blue: 0.459, alpha: 1),
        builtin:    NSColor(red: 0.502, green: 0.251, blue: 0.000, alpha: 1), // #804000 dark orange
        variable:   NSColor(red: 0.063, green: 0.251, blue: 0.502, alpha: 1), // #104080 dark blue
        jsonKey:    NSColor(red: 0.000, green: 0.000, blue: 0.800, alpha: 1)
    )

    // MARK: - Bash — terminal green Dark
    static let bashDark = SyntaxNSTheme(
        background: NSColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1),
        plainText:  NSColor(red: 0.970, green: 0.970, blue: 0.950, alpha: 1),
        keyword:    NSColor(red: 0.365, green: 0.847, blue: 1.000, alpha: 1), // #5DD8FF cyan (echo, cd, if...)
        type_:      NSColor(red: 0.970, green: 0.970, blue: 0.950, alpha: 1), // plain
        string:     NSColor(red: 0.878, green: 0.820, blue: 0.494, alpha: 1), // #E0D17E yellow
        number:     NSColor(red: 0.682, green: 0.855, blue: 0.620, alpha: 1), // light green
        comment:    NSColor(red: 0.424, green: 0.475, blue: 0.525, alpha: 1),
        builtin:    NSColor(red: 0.365, green: 0.847, blue: 1.000, alpha: 1), // same as keyword
        variable:   NSColor(red: 0.682, green: 0.855, blue: 0.620, alpha: 1), // #AEDB9E green ($VAR)
        jsonKey:    NSColor(red: 0.365, green: 0.847, blue: 1.000, alpha: 1)
    )

    // MARK: - Bash — terminal Light
    static let bashLight = SyntaxNSTheme(
        background: NSColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1),
        plainText:  NSColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1),
        keyword:    NSColor(red: 0.000, green: 0.000, blue: 0.800, alpha: 1), // blue
        type_:      NSColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1),
        string:     NSColor(red: 0.647, green: 0.161, blue: 0.161, alpha: 1), // dark red
        number:     NSColor(red: 0.063, green: 0.502, blue: 0.063, alpha: 1),
        comment:    NSColor(red: 0.408, green: 0.435, blue: 0.459, alpha: 1),
        builtin:    NSColor(red: 0.000, green: 0.000, blue: 0.800, alpha: 1),
        variable:   NSColor(red: 0.063, green: 0.502, blue: 0.063, alpha: 1), // dark green ($VAR)
        jsonKey:    NSColor(red: 0.000, green: 0.000, blue: 0.800, alpha: 1)
    )

    // MARK: - SQL Dark
    static let sqlDark = SyntaxNSTheme(
        background: NSColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1),
        plainText:  NSColor(red: 0.970, green: 0.970, blue: 0.950, alpha: 1),
        keyword:    NSColor(red: 0.337, green: 0.612, blue: 0.878, alpha: 1), // #569CD6 blue
        type_:      NSColor(red: 0.970, green: 0.970, blue: 0.950, alpha: 1), // plain
        string:     NSColor(red: 0.988, green: 0.416, blue: 0.365, alpha: 1), // red-orange
        number:     NSColor(red: 0.682, green: 0.855, blue: 0.620, alpha: 1), // light green
        comment:    NSColor(red: 0.424, green: 0.475, blue: 0.525, alpha: 1),
        builtin:    NSColor(red: 0.267, green: 0.788, blue: 0.733, alpha: 1), // teal (COUNT, SUM...)
        variable:   NSColor(red: 0.970, green: 0.970, blue: 0.950, alpha: 1),
        jsonKey:    NSColor(red: 0.337, green: 0.612, blue: 0.878, alpha: 1)
    )

    // MARK: - SQL Light
    static let sqlLight = SyntaxNSTheme(
        background: NSColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1),
        plainText:  NSColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1),
        keyword:    NSColor(red: 0.000, green: 0.000, blue: 0.800, alpha: 1), // blue
        type_:      NSColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1),
        string:     NSColor(red: 0.647, green: 0.161, blue: 0.161, alpha: 1), // dark red
        number:     NSColor(red: 0.063, green: 0.502, blue: 0.063, alpha: 1),
        comment:    NSColor(red: 0.408, green: 0.435, blue: 0.459, alpha: 1),
        builtin:    NSColor(red: 0.063, green: 0.502, blue: 0.502, alpha: 1), // teal
        variable:   NSColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1),
        jsonKey:    NSColor(red: 0.000, green: 0.000, blue: 0.800, alpha: 1)
    )

    // MARK: - JSON Dark
    // Keys: light blue, string values: orange, numbers: light green, booleans/null: pink
    static let jsonDark = SyntaxNSTheme(
        background: NSColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1),
        plainText:  NSColor(red: 0.970, green: 0.970, blue: 0.950, alpha: 1),
        keyword:    NSColor(red: 0.988, green: 0.373, blue: 0.639, alpha: 1), // pink (true/false/null)
        type_:      NSColor(red: 0.970, green: 0.970, blue: 0.950, alpha: 1),
        string:     NSColor(red: 0.878, green: 0.580, blue: 0.318, alpha: 1), // #E09451 orange (string values)
        number:     NSColor(red: 0.682, green: 0.855, blue: 0.620, alpha: 1), // light green
        comment:    NSColor(red: 0.424, green: 0.475, blue: 0.525, alpha: 1),
        builtin:    NSColor(red: 0.970, green: 0.970, blue: 0.950, alpha: 1),
        variable:   NSColor(red: 0.970, green: 0.970, blue: 0.950, alpha: 1),
        jsonKey:    NSColor(red: 0.365, green: 0.847, blue: 1.000, alpha: 1)  // #5DD8FF light blue (keys)
    )

    // MARK: - JSON Light
    static let jsonLight = SyntaxNSTheme(
        background: NSColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1),
        plainText:  NSColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1),
        keyword:    NSColor(red: 0.659, green: 0.055, blue: 0.565, alpha: 1), // purple (true/false/null)
        type_:      NSColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1),
        string:     NSColor(red: 0.773, green: 0.357, blue: 0.031, alpha: 1), // #C55C08 dark orange (string values)
        number:     NSColor(red: 0.063, green: 0.502, blue: 0.063, alpha: 1), // dark green
        comment:    NSColor(red: 0.408, green: 0.435, blue: 0.459, alpha: 1),
        builtin:    NSColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1),
        variable:   NSColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1),
        jsonKey:    NSColor(red: 0.110, green: 0.384, blue: 0.655, alpha: 1)  // dark blue (keys)
    )

    // MARK: - C / C++ / Java Dark — classic blue-keyword IDE style
    static let cFamilyDark = SyntaxNSTheme(
        background: NSColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1),
        plainText:  NSColor(red: 0.970, green: 0.970, blue: 0.950, alpha: 1),
        keyword:    NSColor(red: 0.337, green: 0.612, blue: 0.878, alpha: 1), // #569CD6 blue
        type_:      NSColor(red: 0.267, green: 0.788, blue: 0.733, alpha: 1), // teal (PascalCase types)
        string:     NSColor(red: 0.565, green: 0.773, blue: 0.502, alpha: 1), // green
        number:     NSColor(red: 0.682, green: 0.855, blue: 0.620, alpha: 1), // light green
        comment:    NSColor(red: 0.424, green: 0.475, blue: 0.525, alpha: 1),
        builtin:    NSColor(red: 0.267, green: 0.788, blue: 0.733, alpha: 1), // teal
        variable:   NSColor(red: 0.970, green: 0.970, blue: 0.950, alpha: 1),
        jsonKey:    NSColor(red: 0.337, green: 0.612, blue: 0.878, alpha: 1)
    )

    // MARK: - C / C++ / Java Light
    static let cFamilyLight = SyntaxNSTheme(
        background: NSColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1),
        plainText:  NSColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1),
        keyword:    NSColor(red: 0.000, green: 0.000, blue: 0.800, alpha: 1), // blue
        type_:      NSColor(red: 0.063, green: 0.502, blue: 0.502, alpha: 1), // teal
        string:     NSColor(red: 0.647, green: 0.161, blue: 0.161, alpha: 1), // dark red
        number:     NSColor(red: 0.063, green: 0.502, blue: 0.063, alpha: 1), // dark green
        comment:    NSColor(red: 0.408, green: 0.435, blue: 0.459, alpha: 1),
        builtin:    NSColor(red: 0.063, green: 0.502, blue: 0.502, alpha: 1),
        variable:   NSColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1),
        jsonKey:    NSColor(red: 0.000, green: 0.000, blue: 0.800, alpha: 1)
    )

    // MARK: - Theme selector

    /// Returns the correct theme for the given normalized language and color scheme.
    static func forLanguage(_ lang: String, dark: Bool) -> SyntaxNSTheme {
        switch lang {
        case "swift", "kotlin", "rust", "go":
            return dark ? .xcodeDefaultDark : .xcodeDefaultLight
        case "python":
            return dark ? .pythonDark : .pythonLight
        case "javascript", "typescript":
            return dark ? .jsDark : .jsLight
        case "bash":
            return dark ? .bashDark : .bashLight
        case "sql":
            return dark ? .sqlDark : .sqlLight
        case "json":
            return dark ? .jsonDark : .jsonLight
        case "c", "cpp", "java":
            return dark ? .cFamilyDark : .cFamilyLight
        default:
            // Unknown language — use Xcode default as a safe fallback
            return dark ? .xcodeDefaultDark : .xcodeDefaultLight
        }
    }
}
