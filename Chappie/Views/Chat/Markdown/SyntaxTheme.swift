// SyntaxTheme.swift
// Chappie

import SwiftUI

// MARK: - SwiftUI Color theme (for CodeBlockView chrome)

/// SwiftUI Color palette for CodeBlockView header/border/label — non-text UI elements.
///
/// SyntaxNSTheme covers the code text itself (NSTextView).
/// SyntaxTheme covers the surrounding chrome: header background, border, label color.
struct SyntaxTheme {

    let background: Color
    let headerBackground: Color
    let border: Color
    let labelColor: Color

    static let dark = SyntaxTheme(
        background:       Color(red: 0.118, green: 0.118, blue: 0.118),
        headerBackground: Color(red: 0.145, green: 0.145, blue: 0.145),
        border:           Color(red: 0.250, green: 0.250, blue: 0.250),
        labelColor:       Color(red: 0.600, green: 0.600, blue: 0.600)
    )

    static let light = SyntaxTheme(
        background:       Color(red: 1.000, green: 1.000, blue: 1.000),
        headerBackground: Color(red: 0.953, green: 0.953, blue: 0.953),
        border:           Color(red: 0.851, green: 0.851, blue: 0.851),
        labelColor:       Color(red: 0.500, green: 0.500, blue: 0.500)
    )
}
