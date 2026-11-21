// ComputerUseTools.swift
//
// Implements computer use tools: screenshot, click, scroll, type.
//
// COORDINATE SPACE:
// The model works in image-space coordinates (pixels of the scaled-down screenshot).
// captureScreen() scales the image to a fixed width (1440px for Retina, native for non-Retina),
// and each action tool divides the given x/y by the same scale factor to get real screen points.
//
// WHY CGEvent INSTEAD OF AXUIElement:
// CGEvent works for any app without requiring accessibility inspection of the target element.
// The model just points at a pixel — we synthesize the event at that location.
//
// SCREENSHOT FORMAT:
// JPEG at 70% quality. PNG on Retina would be 3-5 MB per frame which is expensive per step.
// 1440px wide covers all common screen sizes at readable density.
//
// DELAY BEFORE SCREENSHOT:
// After performing an action we wait `delay` seconds before capturing so the UI has time to
// react. Default 1s for clicks and scroll, same for type. The model increases it for browser
// navigation where page load takes longer.

import Foundation
import CoreGraphics
import AppKit

// MARK: - ComputerUseTools

final class ComputerUseTools: Sendable {

    // MARK: - Constants

    // Target long-side width for Retina screenshots. Non-Retina uses native resolution.
    private static let screenshotTargetWidth: CGFloat = 1440

    // JPEG compression quality: 0.70 gives ~300-600 KB for a full desktop frame.
    private static let jpegQuality: CGFloat = 0.70

    // MARK: - Screenshot

    /// Captures the screen at `screenIndex` and returns a ToolResult with a JPEG image.
    func screenshot(screenIndex: Int) -> ToolResult {
        guard let (image, _) = captureScreen(screenIndex: screenIndex) else {
            return .failure("Failed to capture screen \(screenIndex). Check Screen Recording permission.")
        }
        return imageResult(image, label: "screenshot")
    }

    // MARK: - Click

    func click(
        x: Double, y: Double,
        button: MouseButton,
        count: Int,
        delay: TimeInterval,
        screenIndex: Int
    ) async -> ToolResult {
        guard let (_, scale) = captureScreen(screenIndex: screenIndex) else {
            return .failure("Failed to capture screen \(screenIndex) to resolve coordinates.")
        }

        let screenPoint = imageToScreen(x: x, y: y, scale: scale, screenIndex: screenIndex)

        let cgButton: CGMouseButton
        let downType: CGEventType
        let upType: CGEventType
        switch button {
        case .left:
            cgButton = .left
            downType = count == 2 ? .leftMouseDown : .leftMouseDown
            upType   = count == 2 ? .leftMouseUp   : .leftMouseUp
        case .right:
            cgButton = .right
            downType = .rightMouseDown
            upType   = .rightMouseUp
        case .middle:
            cgButton = .center
            downType = .otherMouseDown
            upType   = .otherMouseUp
        }

        for tap in 1...max(1, count) {
            guard
                let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: screenPoint, mouseButton: cgButton),
                let up   = CGEvent(mouseEventSource: nil, mouseType: upType,   mouseCursorPosition: screenPoint, mouseButton: cgButton)
            else {
                return .failure("Failed to create CGEvent for click (tap \(tap)).")
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)

            // Small gap between double-click taps so the system registers them as a pair.
            if count == 2 && tap == 1 {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        await sleep(seconds: delay)

        guard let (after, _) = captureScreen(screenIndex: screenIndex) else {
            return .failure("Click sent but screenshot after action failed.")
        }
        return imageResult(after, label: "after \(button.rawValue)-click at (\(Int(x)),\(Int(y)))")
    }

    // MARK: - Scroll

    func scroll(
        x: Double, y: Double,
        dx: Double, dy: Double,
        delay: TimeInterval,
        screenIndex: Int
    ) async -> ToolResult {
        guard let (_, scale) = captureScreen(screenIndex: screenIndex) else {
            return .failure("Failed to capture screen \(screenIndex) to resolve coordinates.")
        }

        let screenPoint = imageToScreen(x: x, y: y, scale: scale, screenIndex: screenIndex)

        // CGEvent scroll uses "lines" (ticks). One tick ≈ 3px of physical movement,
        // so we scale dy/dx down to reasonable tick counts.
        let ticksY = Int32((-dy / 3).rounded())
        let ticksX = Int32((-dx / 3).rounded())

        // Axis1 = vertical, Axis2 = horizontal.
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: ticksY,
            wheel2: ticksX,
            wheel3: 0
        ) else {
            return .failure("Failed to create CGEvent for scroll.")
        }
        event.location = screenPoint
        event.post(tap: .cghidEventTap)

        await sleep(seconds: delay)

        guard let (after, _) = captureScreen(screenIndex: screenIndex) else {
            return .failure("Scroll sent but screenshot after action failed.")
        }
        return imageResult(after, label: "after scroll (\(Int(dx)),\(Int(dy))) at (\(Int(x)),\(Int(y)))")
    }

    // MARK: - Type

    func type(
        text: String,
        x: Double?, y: Double?,
        submit: Bool,
        delay: TimeInterval,
        screenIndex: Int
    ) async -> ToolResult {
        // Click to focus the target field if coordinates were given.
        if let x, let y {
            guard let (_, scale) = captureScreen(screenIndex: screenIndex) else {
                return .failure("Failed to capture screen \(screenIndex) to resolve coordinates.")
            }
            let screenPoint = imageToScreen(x: x, y: y, scale: scale, screenIndex: screenIndex)
            guard
                let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: screenPoint, mouseButton: .left),
                let up   = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,   mouseCursorPosition: screenPoint, mouseButton: .left)
            else {
                return .failure("Failed to create click event to focus field.")
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        // Type each character via CGEvent keypress.
        // keyboardSetUnicodeString takes UniChar (UInt16) units, so we encode each Character
        // as UTF-16 code units. Surrogate pairs (emoji, rare CJK) produce two units and are
        // posted as two events — the receiving app reconstructs the full code point.
        for char in text {
            let utf16 = Array(char.utf16)
            guard
                let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                let up   = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else { continue }
            var units = utf16
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &units)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            // Small inter-key delay so apps with key-repeat timers register each keystroke.
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        if submit {
            postKeyPress(keyCode: 0x24) // Return
        }

        await sleep(seconds: delay)

        guard let (after, _) = captureScreen(screenIndex: screenIndex) else {
            return .failure("Text typed but screenshot after action failed.")
        }
        return imageResult(after, label: "after typing \(text.count) chars")
    }

    // MARK: - Private Helpers

    /// Captures the screen at `screenIndex`, scales it down for the model, and returns
    /// the JPEG image plus the scale factor (image_px / screen_pt) used for coordinate mapping.
    private func captureScreen(screenIndex: Int) -> (NSImage, CGFloat)? {
        let screens = NSScreen.screens
        guard screenIndex < screens.count else { return nil }
        let screen = screens[screenIndex]

        // CGDisplayCreateImage needs the CGDirectDisplayID for the chosen screen.
        guard
            let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
            let cgImage  = CGDisplayCreateImage(screenID)
        else { return nil }

        let nativeWidth  = CGFloat(cgImage.width)
        let nativeHeight = CGFloat(cgImage.height)

        // Scale down to targetWidth on Retina; native on non-Retina (already small enough).
        let targetWidth = min(ComputerUseTools.screenshotTargetWidth, nativeWidth)
        let scale       = targetWidth / nativeWidth
        let targetHeight = (nativeHeight * scale).rounded()

        let targetSize = NSSize(width: targetWidth, height: targetHeight)
        let result     = NSImage(size: targetSize)

        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: cgImage, size: NSSize(width: nativeWidth, height: nativeHeight))
            .draw(in: NSRect(origin: .zero, size: targetSize))
        result.unlockFocus()

        return (result, scale)
    }

    /// Converts image-space coordinates (as the model sees them) back to screen points.
    private func imageToScreen(x: Double, y: Double, scale: CGFloat, screenIndex: Int) -> CGPoint {
        let screens = NSScreen.screens
        guard screenIndex < screens.count else { return CGPoint(x: x, y: y) }
        let screen = screens[screenIndex]

        // Model coordinates are in top-left origin; CGEvent uses global Quartz coordinates
        // which originate at the top-left of the primary screen (not necessarily screen 0).
        let screenX = screen.frame.minX + CGFloat(x) / scale
        let screenY = screen.frame.minY + CGFloat(y) / scale

        return CGPoint(x: screenX, y: screenY)
    }

    /// Writes `image` as JPEG to a temp file and returns a ToolResult with media attached.
    private func imageResult(_ image: NSImage, label: String) -> ToolResult {
        let dir  = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chappie_cu_\(ProcessInfo.processInfo.processIdentifier)")
        let file = dir.appendingPathComponent("screen_\(Int(Date().timeIntervalSince1970)).jpg")

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard
                let tiff = image.tiffRepresentation,
                let bmp  = NSBitmapImageRep(data: tiff),
                let jpeg = bmp.representation(using: .jpeg, properties: [.compressionFactor: ComputerUseTools.jpegQuality])
            else {
                return .failure("Failed to encode screenshot as JPEG.")
            }
            try jpeg.write(to: file)
        } catch {
            return .failure("Failed to write screenshot: \(error.localizedDescription)")
        }

        let media = ToolMedia(
            directory: dir.path,
            files: [ToolMediaFile(label: label, path: file.path)]
        )
        return .success("", media: media)
    }

    /// Posts a raw key-down + key-up pair for a given virtual key code.
    private func postKeyPress(keyCode: CGKeyCode) {
        guard
            let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
            let up   = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func sleep(seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: - MouseButton

enum MouseButton: String, Sendable {
    case left, right, middle
}
