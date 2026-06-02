// InputLayoutConstants.swift
// Chappie
//
// Shared layout constants for the input panel.
// Centralized here so all input subviews use identical sizing.
// Named InputLayout (not Layout) to avoid shadowing SwiftUI's Layout protocol.

import CoreGraphics

enum InputLayout {
    static let collapsedHeight: CGFloat = 28
    static let lineHeight: CGFloat = 20
    static let editorVerticalPadding: CGFloat = 6
    static let maxLines: Int = 10

    static let outerHorizontalPadding: CGFloat = 16
    static let outerBottomPadding: CGFloat = 16
    static let innerPadding: CGFloat = 12

    static var maxEditorHeight: CGFloat {
        CGFloat(maxLines) * lineHeight + editorVerticalPadding * 2
    }
    static var minEditorHeight: CGFloat {
        lineHeight + editorVerticalPadding * 2
    }

    // Static footer height for ChatScrollView bottom padding.
    // Computed once at compile time — never changes at runtime.
    // = maxEditorHeight + innerPadding*2 (top+bottom inside panel)
    //   + outerBottomPadding (panel sits 16pt above window edge)
    //   + outerHorizontalPadding (visual breathing room below last message)
    // WHY STATIC: editorHeight growing/shrinking on every keystroke used to
    // propagate up to ContentView → ChatScrollView, causing a layout pass per character.
    // The chat always reserves space for the tallest possible panel — user never
    // sees content hidden behind the input bar.
    static var maxPanelHeight: CGFloat {
        maxEditorHeight + innerPadding * 2 + outerBottomPadding + outerHorizontalPadding
    }
}
