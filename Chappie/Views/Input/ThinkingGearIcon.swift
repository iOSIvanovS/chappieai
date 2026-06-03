// ThinkingGearIcon.swift
// Chappie
//
// Spinning gear icon for the thinking state.
//
// CPU-32: MIGRATED FROM @State + withAnimation TO TimelineView:
//
// Previous implementation used @State angle + withAnimation(.linear.repeatForever).
// Despite the comment claiming "no per-frame overhead", this is incorrect on macOS:
// withAnimation(.repeatForever) creates a CADisplayLink inside SwiftUI's animation system
// that fires at 60fps for the entire duration of the thinking state.
// Each tick triggers SwiftUI's AttributeGraph diff + layout pass — causing ~50% CPU
// while waiting for the AI backend (no network, no disk, just a spinning icon).
//
// Fix: TimelineView(.animation) — single shared display-link for the whole screen.
// Rotation angle is computed mathematically from Date: no @State, no SwiftUI invalidation.
// The view body is a pure function: same timestamp → same angle. Zero side effects.
//
// One full rotation = 2.0 seconds (same as before).

import SwiftUI

struct ThinkingGearIcon: View {

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            // One rotation per 2 seconds — angle computed purely from time.
            let angle = (t.truncatingRemainder(dividingBy: 2.0) / 2.0) * 360.0
            Image(systemName: "gearshape.arrow.triangle.2.circlepath")
                .font(.system(size: 13))
                .rotationEffect(.degrees(angle))
        }
    }
}
