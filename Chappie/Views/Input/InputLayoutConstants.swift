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

    // Footer height for ChatScrollView — reserves space for the COLLAPSED panel.
    // = minEditorHeight + innerPadding*2 + outerBottomPadding + outerHorizontalPadding
    // WHY MIN not MAX: sentinel anchor:.top handles exact positioning.
    // We only need enough clearance so the last message isn't hidden behind the
    // collapsed panel chrome. Using maxPanelHeight (268pt) pushed the last message
    // to the middle of the screen — way too much empty space.
    static var minPanelHeight: CGFloat {
        minEditorHeight + innerPadding * 2 + outerBottomPadding + outerHorizontalPadding
    }

    // Maximum panel height — used by InputMorphView to cap editor growth.
    static var maxPanelHeight: CGFloat {
        maxEditorHeight + innerPadding * 2 + outerBottomPadding + outerHorizontalPadding
    }
}
