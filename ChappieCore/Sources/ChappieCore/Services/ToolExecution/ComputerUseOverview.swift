// ComputerUseOverview.swift
// ChappieCore
//
// WHY THIS FILE:
// computer_screenshot: captures one whole monitor with the real cursor baked in by SCKit,
// then returns the picture plus the cursor position in picture pixels. The model works
// entirely in picture pixels — no fractions, no native resolution, no Retina math.

import Foundation
import CoreGraphics
import AppKit

extension ToolExecutionService {

    /// Captures the monitor and returns a ToolImageResult with cursor coordinates.
    @MainActor
    static func overviewScreenshot(monitor: Int) -> String {
        let count = NSScreen.screens.count
        guard let screen = Self.screen(at: monitor) else {
            return "❌ computer_screenshot: Monitor \(monitor) not found. Connected monitors: \(count)."
        }
        // Capture is async (SCScreenshotManager); bridge via a semaphore so this @MainActor
        // func stays synchronous for callers that cannot be async themselves.
        // This is intentional: captureWithCursor is fast (single frame, no stream setup).
        let semaphore = DispatchSemaphore(value: 0)
        var captured: CGImage?
        Task {
            captured = await Self.captureWithCursor(screen)
            semaphore.signal()
        }
        semaphore.wait()

        guard let full = captured else {
            return "❌ computer_screenshot: Failed to capture monitor \(monitor)."
        }

        // Read cursor position in CGEvent space before building the mapping.
        let cursorEvent: CGPoint
        if let ev = CGEvent(source: nil) {
            cursorEvent = ev.location
        } else {
            let loc = NSEvent.mouseLocation
            cursorEvent = CGPoint(
                x: loc.x,
                y: CGDisplayBounds(CGMainDisplayID()).height - loc.y
            )
        }

        return Self.buildOverviewResult(
            screen: screen,
            monitorIndex: monitor,
            monitorCount: count,
            full: full,
            cursorEventPt: cursorEvent
        )
    }
}
