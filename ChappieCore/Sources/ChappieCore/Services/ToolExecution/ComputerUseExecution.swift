// ComputerUseExecution.swift
// ChappieCore
//
// WHY THIS FILE:
// Execution logic for computer_screenshot, computer_click, computer_scroll, computer_type.
// These tools live in ToolExecutionService (app-side) rather than ChappieMCP because they
// need AppKit/CoreGraphics access that is only available in the main app process.
//
// COORDINATE SPACE:
// All x/y arguments are in screenshot-image pixels (the scaled-down image we return).
// scaleToScreen() maps them back to real CGEvent coordinates. An "element" argument is the
// opposite case: the centre comes from the accessibility tree and is already a CGEvent point.
//
// SCREENSHOT FORMAT:
// JPEG at quality 0.7, long side capped at 1440px, returned behind viewImageMarker so
// AIOrchestrator+ToolExecution injects it as an image block. A numbered screenshot (marks:true,
// and every action result) is a ToolImageResult instead: the element list rides as the tool text
// while the picture follows as a user message.
//
// WHY EVERY ACTION ANSWERS WITH NUMBERS:
// A number is only valid for the picture it was drawn on. Returning a fresh numbered picture from
// each click, scroll and keystroke keeps the model's numbers and the screen in step — one call per
// action instead of a screenshot plus an action.

import Foundation
import CoreGraphics
import AppKit

// Lenient FlexDouble / FlexInt / FlexBool live in ComputerUseArguments.swift.

extension ToolExecutionService {

    /// Numbers of the most recent screenshot, shared by all four computer tools.
    static let markedScreenshots = MarkedScreenshotStore()

    func executeComputerUseTool(name: String, argsData: Data) async throws -> String {
        switch name {
        case "computer_screenshot": return await captureScreenshot(argsData: argsData)
        case "computer_click":     return await performClick(argsData: argsData)
        case "computer_scroll":    return await performScroll(argsData: argsData)
        case "computer_type":      return await performType(argsData: argsData)
        case "computer_aim":       return await performAim(argsData: argsData)
        default:                   return "Error: Unknown computer use tool \(name)"
        }
    }

    // MARK: - Screenshot

    private func captureScreenshot(argsData: Data) async -> String {
        let args = ComputerScreenshotArguments.parse(argsData)
        let region = args.region
        let monitor = args.monitor?.value ?? args.screen_index?.value ?? 0
        let wantsMarks = args.wantsMarks
        // Only the legacy zoom and marks modes keep the old path; a plain call gets the clean overview.
        if wantsMarks || region != nil {
            let grid = args.wantsGrid
            return await MainActor.run {
                wantsMarks
                    ? Self.markedScreenshot(screenIndex: monitor, grid: grid, region: region)
                    : Self.screenshotDataURI(screenIndex: monitor, grid: grid, region: region)
            }
        }
        let grid = args.grid?.value ?? false
        return await MainActor.run {
            Self.overviewScreenshot(monitor: monitor, grid: grid)
        }
    }

    // MARK: - Click

    private func performClick(argsData: Data) async -> String {
        // Accessibility permission is required for CGEvent to reach other apps.
        guard Self.isAccessibilityTrusted() else {
            return "❌ computer_click: Accessibility permission is required. Please grant it in System Settings → Privacy & Security → Accessibility, then try again."
        }
        struct Args: Decodable {
            var button: String?; var count: FlexInt?
            var delay: FlexDouble?
        }
        // take() forgets the aim at once, so a failed or finished click can never reuse a stale point.
        guard let aim = Self.aimStore.take() else {
            return "❌ computer_click: No aim is set. Call computer_aim first, check the crosshair, then click. An aim is used up by one click."
        }
        // All options are optional, so unreadable arguments fall back to a single left click.
        let args = (try? JSONDecoder().decode(Args.self, from: argsData)) ?? Args()
        let screenIndex = aim.monitor
        let clicks      = args.count?.value ?? 1
        let delay       = args.delay?.value ?? 1.0
        let button      = args.button ?? "left"
        let pt          = aim.eventPoint
        let what = String(format: "Clicked the aimed point (x=%.4f y=%.4f of monitor %d).",
                          aim.fraction.x, aim.fraction.y, aim.monitor)
        let (dn, up) = Self.cgButtonTypes(for: button)
        let btn      = Self.cgMouseButton(for: button)

        // Activate the app under the click point BEFORE posting events, so Chappie does
        // not steal focus back. NSWindowList gives us the window owner at that position.
        await MainActor.run {
            Self.activateApp(at: pt)
        }
        // Warp cursor after activation so the OS records the new position before the click.
        CGWarpMouseCursorPosition(pt)
        CGAssociateMouseAndMouseCursorPosition(1)
        try? await Task.sleep(for: .milliseconds(120))
        for i in 0..<clicks {
            Self.postMouseEvent(type: dn, point: pt, button: btn)
            try? await Task.sleep(for: .milliseconds(30))
            Self.postMouseEvent(type: up, point: pt, button: btn)
            if i < clicks - 1 { try? await Task.sleep(for: .milliseconds(100)) }
        }
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        // The click may have moved or replaced the controls: the old numbers die with this line.
        Self.markedScreenshots.clear()
        let label = clicks > 1 ? what.replacingOccurrences(of: "Clicked", with: "Double-clicked") : what
        return await MainActor.run {
            Self.markedScreenshot(screenIndex: screenIndex, grid: false, region: nil, action: label)
        }
    }

    // MARK: - Scroll

    private func performScroll(argsData: Data) async -> String {
        struct Args: Decodable {
            var x: FlexDouble; var y: FlexDouble
            var dx: FlexDouble?; var dy: FlexDouble
            var delay: FlexDouble?; var screen_index: FlexInt?
        }
        guard let args = try? JSONDecoder().decode(Args.self, from: argsData) else {
            return "❌ computer_scroll: Arguments 'x', 'y' and 'dy' are required."
        }
        let screenIndex = args.screen_index?.value ?? 0
        let delay       = args.delay?.value ?? 1.0

        let err: String = await MainActor.run {
            guard let screen = Self.screen(at: screenIndex) else {
                return "❌ computer_scroll: Screen index \(screenIndex) not found."
            }
            let pt         = Self.scaleToScreen(x: args.x.value, y: args.y.value, screen: screen)
            // Positive dy = scroll down (inverted from CGScrollWheelEvent convention).
            let vertTicks  = Int32(-(args.dy.value))
            let horizTicks = Int32(args.dx?.value ?? 0)
            if let event = CGEvent(scrollWheelEvent2Source: nil,
                                   units: .line, wheelCount: 2,
                                   wheel1: vertTicks, wheel2: horizTicks, wheel3: 0) {
                event.location = pt
                event.post(tap: .cghidEventTap)
            }
            return ""
        }
        if !err.isEmpty { return err }
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        let label = "Scrolled \(args.dy.value >= 0 ? "down" : "up") \(abs(Int(args.dy.value))) ticks"
            + " at (\(Int(args.x.value)), \(Int(args.y.value))) on the screenshot grid."
        Self.markedScreenshots.clear()
        return await MainActor.run {
            Self.markedScreenshot(screenIndex: screenIndex, grid: false, region: nil, action: label)
        }
    }

    // MARK: - Type

    private func performType(argsData: Data) async -> String {
        struct Args: Decodable {
            var text: String
            var x: FlexDouble?; var y: FlexDouble?
            var element: FlexInt?
            var submit: FlexBool?; var delay: FlexDouble?; var screen_index: FlexInt?
        }
        guard let args = try? JSONDecoder().decode(Args.self, from: argsData),
              !args.text.isEmpty else {
            return "❌ computer_type: Argument 'text' is required."
        }
        let screenIndex = args.screen_index?.value ?? 0
        let delay       = args.delay?.value ?? 1.0

        // Optional focus: a number from the last numbered picture, or a point on the grid.
        var focusPoint: CGPoint?
        var focusApp: pid_t?
        var focusNote = ""
        if let number = args.element?.value {
            switch Self.resolveElement(number) {
            case .failure(let message):
                return "❌ computer_type(element: \(number)): \(message)"
            case .point(let point, let description, let pid):
                focusPoint = point
                focusApp = pid
                focusNote = " after clicking \(description)"
            }
        }

        let err: String = await MainActor.run {
            if let point = focusPoint {
                // Keystrokes go to the ACTIVE app, so unlike a click this really does need a focus
                // transfer — to the very app whose field was clicked, not to whatever is on top.
                if let pid = focusApp {
                    NSRunningApplication(processIdentifier: pid)?.activate()
                }
                CGWarpMouseCursorPosition(point)
                CGAssociateMouseAndMouseCursorPosition(1)
                Self.postMouseEvent(type: .leftMouseDown, point: point, button: .left)
                Self.postMouseEvent(type: .leftMouseUp,   point: point, button: .left)
            } else if let ix = args.x, let iy = args.y,
                      let screen = Self.screen(at: screenIndex) {
                // Optional focus click from the grid.
                let pt = Self.scaleToScreen(x: ix.value, y: iy.value, screen: screen)
                Self.postMouseEvent(type: .leftMouseDown, point: pt, button: .left)
                Self.postMouseEvent(type: .leftMouseUp,   point: pt, button: .left)
            }
            for scalar in args.text.unicodeScalars {
                Self.postKeyEvent(char: String(scalar), keyDown: true)
                Self.postKeyEvent(char: String(scalar), keyDown: false)
            }
            if args.submit?.value == true {
                Self.postRawKey(keyCode: 36, keyDown: true)   // Return
                Self.postRawKey(keyCode: 36, keyDown: false)
            }
            return ""
        }
        if !err.isEmpty { return err }
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        let typed = "Typed \(args.text.count) character\(args.text.count == 1 ? "" : "s")"
        let label = typed + focusNote + (args.submit?.value == true ? " and pressed Return." : ".")
        Self.markedScreenshots.clear()
        return await MainActor.run {
            Self.markedScreenshot(screenIndex: screenIndex, grid: false, region: nil, action: label)
        }
    }

    // MARK: - Screen lookup
    // Rendering lives in ComputerUseScreenshot.swift.

    @MainActor
    static func screen(at index: Int) -> NSScreen? {
        let screens = NSScreen.screens
        guard index >= 0, index < screens.count else { return nil }
        return screens[index]
    }

    // MARK: - Coordinate mapping
    // Maps image-space (x, y) → CGEvent global coordinates.
    // NSScreen.frame origin is bottom-left; CGEvent Y is flipped (top-left of primary screen).

    @MainActor
    private static func scaleToScreen(x: Double, y: Double, screen: NSScreen) -> CGPoint {
        let frame  = screen.frame
        // Same geometry the renderer uses — a second copy of this math would drift and every
        // click would land slightly off.
        let geo    = ScreenshotGeometry(nativeSize: CGSize(width:  frame.width  * screen.backingScaleFactor,
                                                           height: frame.height * screen.backingScaleFactor))
        let imgW   = geo.imageSize.width
        let imgH   = geo.imageSize.height

        let screenX   = frame.origin.x + (CGFloat(x) / imgW) * frame.width
        let primaryH  = NSScreen.screens[0].frame.height
        let screenYNS = frame.origin.y + frame.height - (CGFloat(y) / imgH) * frame.height
        let screenYCG = primaryH - screenYNS
        return CGPoint(x: screenX, y: screenYCG)
    }

    // MARK: - CGEvent helpers (nonisolated static — no actor state touched)

    // Activate the frontmost app whose window sits at the given screen point.
    // This transfers focus away from Chappie so the subsequent CGEvent lands in the right window.
    @MainActor
    private static func activateApp(at point: CGPoint) {
        // Walk the on-screen window list to find the topmost window that contains the point.
        // CGWindowBounds uses CG coordinates (top-left origin) — same space as `point`.
        let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[CFString: Any]] ?? []

        for info in windowList {
            guard let pid    = info[kCGWindowOwnerPID] as? pid_t,
                  let bounds = info[kCGWindowBounds]   as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"] else { continue }
            let cgRect = CGRect(x: x, y: y, width: w, height: h)
            if cgRect.contains(point) {
                if let app = NSRunningApplication(processIdentifier: pid) {
                    // .activate() without options is the macOS 14+ replacement for
                    // activateIgnoringOtherApps — it always brings the app to front.
                    app.activate()
                }
                return
            }
        }
        // No specific window found — step Chappie out of the way.
        NSApp.hide(nil)
    }

    // Checks Accessibility trust and triggers the system prompt if not trusted.
    // Uses the raw CFString key to avoid Swift 6 strict-concurrency rejection of kAXTrustedCheckOptionPrompt (a C var).
    nonisolated static func isAccessibilityTrusted() -> Bool {
        guard !AXIsProcessTrusted() else { return true }
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        return false
    }

    private static func postMouseEvent(type: CGEventType, point: CGPoint, button: CGMouseButton) {
        guard let e = CGEvent(mouseEventSource: nil,
                              mouseType: type,
                              mouseCursorPosition: point,
                              mouseButton: button) else { return }
        e.post(tap: .cghidEventTap)
    }

    private static func postKeyEvent(char: String, keyDown: Bool) {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown) else { return }
        var uni = Array(char.utf16)
        e.keyboardSetUnicodeString(stringLength: uni.count, unicodeString: &uni)
        e.post(tap: .cghidEventTap)
    }

    private static func postRawKey(keyCode: CGKeyCode, keyDown: Bool) {
        guard let e = CGEvent(keyboardEventSource: nil,
                              virtualKey: keyCode, keyDown: keyDown) else { return }
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
