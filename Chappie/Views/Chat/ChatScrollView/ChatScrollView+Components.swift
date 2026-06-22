// ChatScrollView+Components.swift
// Chappie
//
// Private helper views: DotsIndicator, StreamingTextView, BlinkingCursor.

import SwiftUI

// MARK: - DotsIndicator

// CPU-29: TimelineView-driven waiting indicator — zero @State, zero SwiftUI invalidation.
struct DotsIndicator: View {
    private let dotSize: CGFloat = 7
    private let spacing: CGFloat = 5
    private let period: Double = 1.08

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: spacing) {
                dot(t: t, delay: 0.00)
                dot(t: t, delay: 0.18)
                dot(t: t, delay: 0.36)
            }
            .drawingGroup()
        }
    }

    private func dot(t: Double, delay: Double) -> some View {
        let phase = (t - delay).truncatingRemainder(dividingBy: period) / period
        let v = (sin(phase * 2 * .pi - .pi / 2) + 1) / 2
        return Circle()
            .fill(Color.secondary.opacity(0.6))
            .frame(width: dotSize, height: dotSize)
            .scaleEffect(0.5 + v * 0.5)
            .opacity(0.3 + v * 0.7)
    }
}

// MARK: - StreamingTextView

// CPU-24: Plain text renderer for the live streaming bubble — no Markdown parsing.
struct StreamingTextView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .lineSpacing(4)
            .foregroundStyle(Color.primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - BlinkingCursor

// CPU-30: TimelineView-driven blinking cursor — zero @State, zero SwiftUI invalidation.
struct BlinkingCursor: View {
    private static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    var body: some View {
        TimelineView(.periodic(from: Self.epoch, by: 0.5)) { timeline in
            let slot = Int(timeline.date.timeIntervalSinceReferenceDate / 0.5)
            Text(verbatim: "▍")
                .font(.system(size: 14))
                .foregroundStyle(Color.accentColor)
                .opacity(slot.isMultiple(of: 2) ? 1 : 0)
                .drawingGroup()
        }
    }
}
