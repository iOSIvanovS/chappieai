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
                // Gear icon with CoreAnimation-based symbol effect — zero CPU cost
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

/// Gear icon using CoreAnimation-based symbolEffect — zero CPU overhead.
/// macOS 15+: .rotate (full spin)
/// macOS 14:  .pulse (brightness pulse — also CoreAnimation, no SwiftUI timer)
private struct GearIconView: View {

    var body: some View {
        if #available(macOS 15.0, *) {
            Image(systemName: "gearshape.arrow.triangle.2.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                // CoreAnimation spin — available macOS 15+
                .symbolEffect(.rotate, options: .repeating)
        } else {
            // macOS 14: .pulse is CoreAnimation-based, no @State timer needed
            Image(systemName: "gearshape.arrow.triangle.2.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: .repeating)
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
