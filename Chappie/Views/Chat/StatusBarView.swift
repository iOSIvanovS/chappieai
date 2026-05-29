//
//  StatusBarView.swift
//  Chappie
//
//  WHY THIS FILE EXISTS:
//  Previously each tool call (read_file, write_file, memorize, etc.)
//  added a .toolCall entry to the chat feed. One complex request may trigger
//  20-50 tool calls — this polluted the feed and created a huge list to render,
//  causing lag on window resize and eating 200 MB of memory.
//
//  SOLUTION:
//  Instead of feed entries — a single status bar between the chat and input field.
//  It shows the CURRENT tool call (one element, not thousands).
//  When Chappie finishes — the bar smoothly hides.
//
//  DESIGN:
//  The bar is intentionally subtle: small font, muted color, icon + text.
//  It should not distract from the conversation — it's a "process hint", not content.

import SwiftUI

/// Status bar — shows the current Chappie tool call.
///
/// Visible only when `toolCall != nil`, i.e. while Chappie is actively
/// calling tools. Smoothly appears and disappears via animation.
struct StatusBarView: View {

    /// Current status string like "read_file → ContentView.swift"
    /// nil = bar is hidden (Chappie is idle or finished)
    let toolCall: String?

    var body: some View {
        // Using if let with animation via .transition — the bar smoothly
        // slides in from the bottom and fades out without abrupt layout shifts.
        if let toolCall = toolCall {
            HStack(spacing: 6) {
                // Spinning gear icon — universal "working" symbol
                GearIconView()

                // Text like "read_file → ContentView.swift"
                Text(toolCall)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    // Long strings are truncated in the middle: preserves start and end
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(
                // Thin translucent strip — does not cover the background,
                // but visually separates the bar from chat and input field
                Color(NSColor.windowBackgroundColor).opacity(0.85)
            )
            .overlay(alignment: .top) {
                // Thin separator line on top — separates from chat
                Divider()
            }
            // Smooth slide-in from the bottom — less aggressive than .opacity,
            // does not cause layout jumps in adjacent components
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Gear Icon

/// Gear icon with rotation animation.
/// Uses .rotate symbolEffect on macOS 15+, falls back to a simple opacity pulse on macOS 14.
private struct GearIconView: View {
    // Fallback animation state for macOS 14
    @State private var pulsing = false

    var body: some View {
        if #available(macOS 15.0, *) {
            Image(systemName: "gearshape.arrow.triangle.2.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                // Rotation effect signals ongoing work — available macOS 15+
                .symbolEffect(.rotate, options: .repeating)
        } else {
            // macOS 14 fallback: gentle opacity pulse instead of rotation
            Image(systemName: "gearshape.arrow.triangle.2.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .opacity(pulsing ? 0.4 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
                .onAppear { pulsing = true }
        }
    }
}

// MARK: - Preview

#Preview("Active call") {
    VStack {
        Spacer()
        StatusBarView(toolCall: "write_file → Chappie/Views/Chat/StatusBarView.swift")
    }
    .frame(width: 600, height: 100)
}

#Preview("Long path (truncation)") {
    VStack {
        Spacer()
        StatusBarView(toolCall: "read_file → ChappieCore/Sources/ChappieCore/Services/AIOrchestrator.swift")
    }
    .frame(width: 400, height: 100)
}

#Preview("Hidden (no activity)") {
    VStack {
        Spacer()
        StatusBarView(toolCall: nil)
    }
    .frame(width: 600, height: 100)
}
