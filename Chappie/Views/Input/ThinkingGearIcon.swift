// ThinkingGearIcon.swift
// Chappie
//
// Spinning gear icon for the thinking state.
// macOS 15+: .rotate symbolEffect. macOS 14: opacity pulse fallback.
//
// WHY isActive PARAMETER:
// .symbolEffect(.rotate, options: .repeating) is a timer-driven animation loop.
// On macOS 15 it runs even when the view is hidden (opacity: 0) — costing ~10% CPU idle.
// Fix: render this view ONLY when isActive == true. Caller gates visibility.

import SwiftUI

struct ThinkingGearIcon: View {
    var isActive: Bool = true
    @State private var pulsing = false

    var body: some View {
        if #available(macOS 15.0, *) {
            Image(systemName: "gearshape.arrow.triangle.2.circlepath")
                .font(.system(size: 13))
                .symbolEffect(.rotate, options: .repeating, isActive: isActive)
        } else {
            Image(systemName: "gearshape.arrow.triangle.2.circlepath")
                .font(.system(size: 13))
                .opacity(pulsing ? 0.4 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
                .onAppear { pulsing = isActive }
                .onChange(of: isActive) { _, active in pulsing = active }
        }
    }
}
