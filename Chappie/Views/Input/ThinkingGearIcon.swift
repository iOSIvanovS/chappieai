// ThinkingGearIcon.swift
// Chappie
//
// Spinning gear icon for the thinking state.
//
// WHY rotationEffect instead of symbolEffect(.rotate):
// symbolEffect(.rotate, options: .repeating) runs a CoreAnimation CADisplayLink timer
// continuously — costing ~10-15% CPU even when nothing visually changes.
// rotationEffect + withAnimation(.linear.repeatForever) creates ONE animator on onAppear
// and reuses it — no per-frame overhead, no CADisplayLink churn.
//
// WHY @State angle + onAppear:
// The animation is started once and runs on the render thread.
// No SwiftUI invalidation on each frame — the view body is not re-evaluated per tick.

import SwiftUI

struct ThinkingGearIcon: View {

    @State private var angle: Double = 0

    var body: some View {
        Image(systemName: "gearshape.arrow.triangle.2.circlepath")
            .font(.system(size: 13))
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}
