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
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)

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
}
