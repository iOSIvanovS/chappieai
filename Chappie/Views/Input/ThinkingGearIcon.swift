// ThinkingGearIcon.swift
// Chappie
//
// Spinning gear icon for the thinking state.
//
// CPU history:
// v1: @State + withAnimation(.repeatForever) — CADisplayLink at 60fps, ~50% CPU
// v2: TimelineView(.animation) — still 60fps display-link, ~25% CPU
// v3: TimelineView(.periodic, 20fps) — capped at 20fps, ~25% CPU (no improvement)
// v4: animation commented out for CPU diagnosis → confirmed 1% CPU (TimelineView was the culprit)
// v5 (current): TimelineView(.periodic, 8fps / 0.125s) — ~2x faster than blinker, target ~2-3% CPU

import SwiftUI

struct ThinkingGearIcon: View {

    var body: some View {
        // 8fps: smooth enough to look alive, cheap enough to not hurt CPU.
        // Full rotation every 2 seconds (360° / 8 steps = 45° per frame).
        TimelineView(.periodic(from: .now, by: 0.125)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let angle = (t.truncatingRemainder(dividingBy: 2.0) / 2.0) * 360.0
            Image(systemName: "gearshape.arrow.triangle.2.circlepath")
                .font(.system(size: 13))
                .rotationEffect(.degrees(angle))
        }
    }
}
