// ComputerUseExecution.swift
// ChappieCore
//
// WHY THIS FILE:
// Entry point and execution for the computer tools. Routing, mouse/keyboard helpers, and the
// new cursor-first flow all live here. The model moves the cursor with computer_move_to or
// computer_move_by, sees the result in a screenshot with the real cursor baked in by SCKit,
// and calls computer_click to click wherever the cursor now sits — no AimStore, no fractions.
//
// COORDINATE SPACE:
// The model works entirely in picture pixels (the compressed image it sees). MonitorMapping
// in ComputerUseScreenshot.swift converts to CGEvent space (top-left of the main display)
// before any event is posted. The model never does that conversion.

import Foundation
import CoreGraphics
import AppKit

extension ToolExecutionService {

    func executeComputerUseTool(name: String, argsData: Data) async throws -> String {
        switch name {
        case "computer_screenshot": return await captureScreenshot(argsData: argsData)
        case "computer_move_to":    return await performMoveTo(argsData: argsData)
        case "computer_move_by":    return await performMoveBy(argsData: argsData)
        case "computer_click":      return await performClick(argsData: argsData)
        case "computer_scroll":     return await performFractionScroll(argsData: argsData)
        case "computer_type":       return await performAimedType(argsData: argsData)
        default:                    return "Error: Unknown computer use tool \(name)"
        }
    }

    // MARK: - Screenshot

    private func captureScreenshot(argsData: Data) async -> String {
        let args = ComputerScreenshotArguments.parse(argsData)
        let monitor = args.monitor?.value ?? args.screen_index?.value ?? 0
        return await Self.overviewScreenshot(monitor: monitor)
    }

    // MARK: - Move to absolute picture position

    private func performMoveTo(argsData: Data) async -> String {
        struct Args: Decodable {
            var x: FlexDouble?
            var y: FlexDouble?
            var monitor: FlexInt?
            var delay: FlexDouble?
        }
        let raw = String(data: argsData, encoding: .utf8) ?? "<non-utf8>"
        guard let args = try? JSONDecoder().decode(Args.self, from: argsData),
              let x = args.x?.value, let y = args.y?.value else {
            return "❌ computer_move_to: 'x' and 'y' are required (picture pixels). Raw args: \(raw)"
        }
        let monitor = args.monitor?.value ?? 0
        let delay   = args.delay?.value ?? 0.3

        // Mapping comes from display geometry only — no live capture needed to warp the cursor.
        let moved: Bool = await MainActor.run {
            guard let mapping = Self.monitorMapping(monitor: monitor) else { return false }
            let target = mapping.toEvent(CGPoint(x: x, y: y))
            CGWarpMouseCursorPosition(target)
            CGAssociateMouseAndMouseCursorPosition(1)
            Self.postMouseMoved(to: target)
            return true
        }
        guard moved else { return "❌ computer_move_to: Monitor \(monitor) not found." }
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        return await Self.overviewScreenshot(monitor: monitor)
    }

    // MARK: - Move by relative delta

    private func performMoveBy(argsData: Data) async -> String {
        struct Args: Decodable {
            var dx: FlexDouble?
            var dy: FlexDouble?
            var monitor: FlexInt?
            var delay: FlexDouble?
        }
        let raw = String(data: argsData, encoding: .utf8) ?? "<non-utf8>"
        guard let args = try? JSONDecoder().decode(Args.self, from: argsData),
              (args.dx != nil || args.dy != nil) else {
            return "❌ computer_move_by: at least one of 'dx' or 'dy' is required (picture pixels). Raw args: \(raw)"
        }
        let dx      = args.dx?.value ?? 0
        let dy      = args.dy?.value ?? 0
        let monitor = args.monitor?.value ?? 0
        let delay   = args.delay?.value ?? 0.3

        // dx/dy are picture pixels: scale them to event points by displayWidth / pictureWidth,
        // then add to the live cursor position (already in CGEvent space, any monitor).
        let eventPt: CGPoint? = await MainActor.run {
            guard let mapping = Self.monitorMapping(monitor: monitor) else { return nil }
            let sx = mapping.displayBounds.width  / max(mapping.pictureSize.width,  1)
            let sy = mapping.displayBounds.height / max(mapping.pictureSize.height, 1)
            let current = Self.currentCursorPosition()
            return CGPoint(x: current.x + dx * sx, y: current.y + dy * sy)
        }
        guard let eventPt else { return "❌ computer_move_by: Monitor \(monitor) not found." }
        CGWarpMouseCursorPosition(eventPt)
        CGAssociateMouseAndMouseCursorPosition(1)
        Self.postMouseMoved(to: eventPt)
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        return await Self.overviewScreenshot(monitor: monitor)
    }

    // MARK: - Click at current cursor position

    private func performClick(argsData: Data) async -> String {
        guard Self.isAccessibilityTrusted() else {
            return "❌ computer_click: Accessibility permission required. Grant it in System Settings → Privacy & Security → Accessibility, then try again."
        }
        struct Args: Decodable {
            var button: String?
            var count:  FlexInt?
            var delay:  FlexDouble?
            var monitor: FlexInt?
        }
        let args    = (try? JSONDecoder().decode(Args.self, from: argsData)) ?? Args()
        let clicks  = args.count?.value  ?? 1
        let delay   = args.delay?.value  ?? 1.0
        let button  = args.button        ?? "left"
        let monitor = args.monitor?.value ?? 0

        let pt: CGPoint = await MainActor.run { Self.currentCursorPosition() }

        await MainActor.run { Self.activateApp(at: pt) }
        CGWarpMouseCursorPosition(pt)
        CGAssociateMouseAndMouseCursorPosition(1)
        Self.postMouseMoved(to: pt)
        try? await Task.sleep(for: .milliseconds(120))

        let (dn, up) = Self.cgButtonTypes(for: button)
        let btn      = Self.cgMouseButton(for: button)
        for i in 0..<clicks {
            Self.postMouseEvent(type: dn, point: pt, button: btn)
            try? await Task.sleep(for: .milliseconds(30))
            Self.postMouseEvent(type: up, point: pt, button: btn)
            if i < clicks - 1 { try? await Task.sleep(for: .milliseconds(100)) }
        }
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        return await Self.overviewScreenshot(monitor: monitor)
    }

    // MARK: - Shared geometry helpers

    /// Builds the picture↔event mapping for a monitor, or nil when the index is out of range.
    @MainActor
    static func monitorMapping(monitor: Int) -> MonitorMapping? {
        guard let screen = screen(at: monitor) else { return nil }
        let bounds = CGDisplayBounds(displayID(of: screen))
        // Must match the captured image size: points times backing scale (device pixels).
        let backing = screen.backingScaleFactor
        return MonitorMapping(
            displayBounds: bounds,
            nativeSize: CGSize(width: bounds.width * backing, height: bounds.height * backing)
        )
    }

    /// Live cursor position in CGEvent space (top-left origin, spans all monitors).
    @MainActor
    static func currentCursorPosition() -> CGPoint {
        if let ev = CGEvent(source: nil) { return ev.location }
        let loc = NSEvent.mouseLocation
        return CGPoint(x: loc.x, y: CGDisplayBounds(CGMainDisplayID()).height - loc.y)
    }

    // MARK: - App activation

    @MainActor
    static func activateApp(at point: CGPoint) {
        let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[CFString: Any]] ?? []
        for info in windowList {
            guard let pid    = info[kCGWindowOwnerPID] as? pid_t,
                  let bounds = info[kCGWindowBounds]   as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"] else { continue }
            if CGRect(x: x, y: y, width: w, height: h).contains(point) {
                NSRunningApplication(processIdentifier: pid)?.activate()
                return
            }
        }
        NSApp.hide(nil)
    }

    // MARK: - Accessibility

    nonisolated static func isAccessibilityTrusted() -> Bool {
        guard !AXIsProcessTrusted() else { return true }
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        return false
    }

    // MARK: - CGEvent helpers

    static func postMouseEvent(type: CGEventType, point: CGPoint, button: CGMouseButton) {
        guard let e = CGEvent(mouseEventSource: nil,
                              mouseType: type,
                              mouseCursorPosition: point,
                              mouseButton: button) else { return }
        e.flags = []
        e.post(tap: .cghidEventTap)
    }

    /// Warping the cursor emits no mouseMoved event, so apps (browsers especially) never learn
    /// the pointer moved; post one explicitly.
    static func postMouseMoved(to point: CGPoint) {
        guard let e = CGEvent(mouseEventSource: nil,
                              mouseType: .mouseMoved,
                              mouseCursorPosition: point,
                              mouseButton: .left) else { return }
        e.flags = []
        e.post(tap: .cghidEventTap)
    }

    static func postRawKey(keyCode: CGKeyCode, keyDown: Bool) {
        guard let e = CGEvent(keyboardEventSource: nil,
                              virtualKey: keyCode, keyDown: keyDown) else { return }
        e.flags = []
        e.post(tap: .cghidEventTap)
    }

    private static func cgButtonTypes(for button: String) -> (CGEventType, CGEventType) {
        switch button {
        case "right":  return (.rightMouseDown, .rightMouseUp)
        case "middle": return (.otherMouseDown, .otherMouseUp)
        default:       return (.leftMouseDown,  .leftMouseUp)
        }
    }

    private static func cgMouseButton(for button: String) -> CGMouseButton {
        switch button {
        case "right":  return .right
        case "middle": return .center
        default:       return .left
        }
    }
}
