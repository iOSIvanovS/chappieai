// BlurGradientView.swift
// Chappie
//
// WHY THIS FILE EXISTS:
// Shared UI primitives for the floating panels layout.
// BlurGradientView combines NSVisualEffectView (system blur) with a gradient mask
// that fades the blur in/out along one axis — creating the "floating panel" effect
// where content underneath the panel softly shows through the edges.
//
// USED BY:
// ContentView — top panel (topToBottom) and bottom panel (bottomToTop).

import SwiftUI
import AppKit

// MARK: - BlurGradientView

/// NSVisualEffectView wrapped in a gradient mask.
///
/// direction = .topToBottom → opaque at top, fades to transparent at bottom (top panel).
/// direction = .bottomToTop → opaque at bottom, fades to transparent at top (bottom panel).
struct BlurGradientView: View {

    enum Direction {
        case topToBottom
        case bottomToTop
    }

    let direction: Direction

    var body: some View {
        ZStack {
            // System blur material — adapts to light/dark mode automatically
            VisualEffectBlur()

            // Gradient that softens the blur edge using destinationOut blend mode.
            // The gradient shape is "cut out" from the blur layer,
            // making the blur fade to transparent at the soft edge.
            LinearGradient(
                gradient: Gradient(stops: gradientStops),
                startPoint: .top,
                endPoint: .bottom
            )
            .blendMode(.destinationOut)
        }
        // compositingGroup is REQUIRED for destinationOut to work correctly —
        // without it the blend mode applies to the entire view hierarchy, not just this ZStack.
        .compositingGroup()
    }

    private var gradientStops: [Gradient.Stop] {
        switch direction {
        case .topToBottom:
            // Top panel: fully opaque at top, fades to clear at bottom edge
            return [
                .init(color: .black, location: 0.0),
                .init(color: .black, location: 0.65),
                .init(color: .clear, location: 1.0)
            ]
        case .bottomToTop:
            // Bottom panel: fully opaque at bottom, fades to clear at top edge
            return [
                .init(color: .clear, location: 0.0),
                .init(color: .black, location: 0.35),
                .init(color: .black, location: 1.0)
            ]
        }
    }
}

// MARK: - VisualEffectBlur

/// NSVisualEffectView representable — provides native macOS frosted glass blur.
/// Uses .hudWindow material: clean semi-transparent blur that works in both light and dark mode.
struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
