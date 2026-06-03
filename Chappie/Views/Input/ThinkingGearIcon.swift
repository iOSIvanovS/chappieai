// ThinkingGearIcon.swift
// Chappie
//
// Spinning gear icon for the thinking state.
//
// CPU history:
// v1: @State + withAnimation(.repeatForever) — CADisplayLink at 60fps, ~50% CPU
// v2: TimelineView(.animation) — still 60fps display-link, ~25% CPU
// v3 (current): TimelineView(.periodic, 20fps) — capped at 20fps.
//    A spinning gear is perceptually smooth at 20fps. No need for 60fps.
//    Deployment target is macOS 14.0 — symbolEffect(.rotate) requires macOS 15+.
//    20fps = 3x less CPU than 60fps with no visible quality difference.

import SwiftUI

struct ThinkingGearIcon: View {

    var body: some View {
        // 20fps is perceptually identical to 60fps for a slow rotation.
        // .periodic fires at fixed intervals — no display-link, no overdraw.
        TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let angle = (t.truncatingRemainder(dividingBy: 2.0) / 2.0) * 360.0
            Image(systemName: "gearshape.arrow.triangle.2.circlepath")
                .font(.system(size: 13))
                .rotationEffect(.degrees(angle))
        }
    }
}
