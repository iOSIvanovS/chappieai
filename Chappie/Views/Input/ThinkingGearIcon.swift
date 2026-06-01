// ThinkingGearIcon.swift
// Chappie
//
// Spinning gear icon for the thinking state.
// macOS 15+: .rotate symbolEffect. macOS 14: opacity pulse fallback.

import SwiftUI

struct ThinkingGearIcon: View {
    @State private var pulsing = false

    var body: some View {
        if #available(macOS 15.0, *) {
            Image(systemName: "gearshape.arrow.triangle.2.circlepath")
                .font(.system(size: 13))
                // Rotation signals active processing — available macOS 15+
                .symbolEffect(.rotate, options: .repeating)
        } else {
            // macOS 14 fallback: gentle opacity pulse
            Image(systemName: "gearshape.arrow.triangle.2.circlepath")
                .font(.system(size: 13))
                .opacity(pulsing ? 0.4 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
                .onAppear { pulsing = true }
        }
    }
}
