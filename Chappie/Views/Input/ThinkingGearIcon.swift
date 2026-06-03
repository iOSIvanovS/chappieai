// ThinkingGearIcon.swift
// Chappie
//
// Spinning gear icon for the thinking state.
//
// CPU history:
// v1: @State + withAnimation(.repeatForever) — CADisplayLink at 60fps, ~50% CPU
// v2: TimelineView(.animation) — still 60fps display-link, ~25% CPU
// v3: TimelineView(.periodic, 20fps) — capped at 20fps, ~25% CPU (no improvement)
// v4 (current): animation commented out for CPU diagnosis.
//    Static gear = 0% CPU. If CPU drops to ~0% — TimelineView was the culprit.
//    Deployment target is macOS 14.0 — symbolEffect(.rotate) requires macOS 15+.

import SwiftUI

struct ThinkingGearIcon: View {

    var body: some View {
        // CPU DIAGNOSIS: animation commented out to isolate 25% CPU source.
        // If CPU drops to ~0% while thinking — TimelineView(.periodic) was the cause.
        // Restore animation block below once diagnosis is complete.
        Image(systemName: "gearshape.arrow.triangle.2.circlepath")
            .font(.system(size: 13))

        // --- ANIMATION (commented for CPU diagnosis) ---
        // TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { timeline in
        //     let t = timeline.date.timeIntervalSinceReferenceDate
        //     let angle = (t.truncatingRemainder(dividingBy: 2.0) / 2.0) * 360.0
        //     Image(systemName: "gearshape.arrow.triangle.2.circlepath")
        //         .font(.system(size: 13))
        //         .rotationEffect(.degrees(angle))
        // }
    }
}
