// InputMorphView+Thinking.swift
// Chappie
//
// Thinking state UI: progress indicator, tool call text, cancel button.

import SwiftUI

extension InputMorphView {

    // MARK: - Thinking View

    var thinkingView: some View {
        HStack(spacing: 12) {
            // CPU-30: NSProgressIndicator under the hood — GPU/CoreAnimation animated, ~0% CPU.
            // Previously ThinkingGearIcon used TimelineView which was confirmed ~25% CPU culprit.
            indicator

            // CPU-23: currentToolCall throttled to 200ms in StreamingState — at most 5 redraws/sec.
            // CPU-29: NO .animation here — cross-fade runs two render passes simultaneously.
            // At 200ms cadence, instant text swap is imperceptible and costs nothing.
            Text(streaming.retryLabel ?? streaming.currentToolCall ?? String(localized: "input.thinking"))
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button(action: onCancel) {
                Label("input.cancel", systemImage: "xmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("input.cancel_help")
        }
        .frame(height: InputLayout.collapsedHeight)
    }

    /// While a tool with a watchdog deadline runs, the spinner is replaced by a pie that fills
    /// clockwise in the tint colour. Nothing else in the row changes size, so the label never jumps.
    @ViewBuilder
    private var indicator: some View {
        if let budget = streaming.toolBudget {
            ToolBudgetPie(window: budget)
                .frame(width: 16, height: 16)
                .help("input.tool_budget_help")
        } else {
            // CPU-30: NSProgressIndicator under the hood, ~0% CPU.
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)
        }
    }
}

/// Pie that fills over the watchdog window. Redraws once per second, only this 16pt view
/// (a continuous animation would redraw at frame rate for the whole tool duration).
private struct ToolBudgetPie: View {
    let window: ClosedRange<Date>

    var body: some View {
        TimelineView(.periodic(from: window.lowerBound, by: 1)) { context in
            let total = window.upperBound.timeIntervalSince(window.lowerBound)
            let elapsed = context.date.timeIntervalSince(window.lowerBound)
            let fraction = total > 0 ? min(max(elapsed / total, 0), 1) : 1
            ZStack {
                Circle().stroke(.tint.opacity(0.35), lineWidth: 1.5)
                PieSlice(fraction: fraction)
                    .fill(.tint)
                    .padding(3)
            }
        }
    }
}

private struct PieSlice: Shape {
    var fraction: Double

    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(
            center: center,
            radius: min(rect.width, rect.height) / 2,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * fraction),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
