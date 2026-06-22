// ChatScrollView+Bubbles.swift
// Chappie
//
// Subviews: streamingBubble, loadMoreButton, threadLoadingIndicator.

import SwiftUI

extension ChatScrollView {

    /// Live streaming bubble shown while AI is generating a response.
    /// CPU-24: plain text during stream — no Markdown parsing overhead.
    var streamingBubble: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                HStack(alignment: .bottom, spacing: 0) {
                    StreamingTextView(text: streaming.streamingText)
                    BlinkingCursor()
                        .padding(.bottom, 1)
                }
                .padding(.bottom, 18)

                // CPU-27: animation removed — fires on every token (30+/sec).
                Text(String(format: "🪙 %.2f ₽", streaming.runningCost))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: streaming.runningCost))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 12,
                    bottomLeadingRadius: 4,
                    bottomTrailingRadius: 12,
                    topTrailingRadius: 12
                )
            )
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 12,
                    bottomLeadingRadius: 4,
                    bottomTrailingRadius: 12,
                    topTrailingRadius: 12
                )
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .frame(maxWidth: max(availableWidth * 0.88, 220))

            Spacer(minLength: 40)
        }
    }

    /// Button shown at the top of the list when older messages are available.
    var loadMoreButton: some View {
        Button(action: onLoadMore) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 13, weight: .medium))
                Text("chat.load_earlier")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    /// Spinner shown while thread messages are being loaded from SwiftData.
    /// Replaces the flash of empty chat that was visible before _syncTask completed.
    var threadLoadingIndicator: some View {
        VStack(spacing: 12) {
            DotsIndicator()
            Text("chat.loading")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
