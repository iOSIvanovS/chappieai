// ComputerUseOverview.swift
// ChappieCore
//
// WHY THIS FILE:
// computer_screenshot: captures one whole monitor with the real cursor baked in by SCKit,
// then returns the picture plus the cursor tip as fractions of the monitor. Fractions are the
// only unit the model uses: they survive any rescaling of the picture, ours or the provider's.

import Foundation
import CoreGraphics
import AppKit

extension ToolExecutionService {

    /// Captures the monitor and returns a ToolImageResult with cursor coordinates.
    @MainActor
    static func overviewScreenshot(monitor: Int) async -> String {
        let count = NSScreen.screens.count
        guard let screen = Self.screen(at: monitor) else {
            return "❌ computer_screenshot: Monitor \(monitor) not found. Connected monitors: \(count)."
        }

        // Obtain displayID on MainActor, then leave the actor for the SC capture so the
        // SCScreenshotManager completion handler is not forced back onto a busy main thread.
        let dispID = Self.displayID(of: screen)
        guard let full = await Self.captureWithCursor(displayID: dispID) else {
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
