// ComputerUseScreenshot.swift
// ChappieCore
//
// WHY THIS FILE:
// Screen capture shared by all computer tools. Uses SCScreenshotManager so the system draws
// the real cursor into the image — the cursor's shape, position, and hotspot are always truthful.
// MonitorMapping translates between fractions of the monitor (the only unit the model uses, immune
// to any rescaling of the picture) and CGEvent space (what the OS uses for mouse coordinates).

import Foundation
import CoreGraphics
import AppKit
import ScreenCaptureKit

/// Translates between the compressed picture the model sees and CGEvent screen coordinates.
///
/// The model works in fractions of the monitor. `toEvent(fraction:)` converts to the CGEvent
/// coordinate, `toFraction` goes the other way. The picture size only matters for rendering.
struct MonitorMapping {
    /// Long side cap keeps token cost predictable. Providers reject images larger than 1568px
    /// on the long side, so staying at 1440 avoids a silent resize that would break pixel math.
    static let overviewMaxSide: CGFloat = 1440

    /// CGDisplayBounds of the monitor (points, top-left origin of the main display).
    let displayBounds: CGRect
    /// Native capture size in device pixels.
    let nativeSize: CGSize
    /// Scale from native pixels to picture pixels.
    let scale: CGFloat
    /// Picture size in pixels (what the model sees).
    let pictureSize: CGSize

    init(displayBounds: CGRect, nativeSize: CGSize) {
        self.displayBounds = displayBounds
        self.nativeSize = nativeSize
        let longest = max(nativeSize.width, nativeSize.height, 1)
        scale = min(1.0, MonitorMapping.overviewMaxSide / longest)
        pictureSize = CGSize(
            width:  (nativeSize.width  * scale).rounded(),
            height: (nativeSize.height * scale).rounded()
        )
    }

    /// Fraction of the monitor (0...1 on each axis, top-left origin) → CGEvent point.
    /// Out-of-range and NaN input is clamped, so a bad number lands on the display edge.
    func toEvent(fraction f: CGPoint) -> CGPoint {
        CGPoint(
            x: displayBounds.minX + MonitorMapping.unit(f.x) * displayBounds.width,
            y: displayBounds.minY + MonitorMapping.unit(f.y) * displayBounds.height
        )
    }

    /// CGEvent point → fraction of the monitor, clamped to 0...1.
    func toFraction(_ eventPt: CGPoint) -> CGPoint {
        CGPoint(
            x: MonitorMapping.unit((eventPt.x - displayBounds.minX) / max(displayBounds.width, 1)),
            y: MonitorMapping.unit((eventPt.y - displayBounds.minY) / max(displayBounds.height, 1))
        )
    }

    /// A fractional delta → CGEvent point offset (no clamping; the caller keeps the result on screen).
    func eventDelta(fraction d: CGPoint) -> CGPoint {
        CGPoint(x: d.x * displayBounds.width, y: d.y * displayBounds.height)
    }

    /// Fractions are model input and may be NaN or out of range.
    static func unit(_ v: CGFloat) -> CGFloat { v.isNaN ? 0.5 : min(max(v, 0), 1) }

    /// Formats a fraction with the fixed precision the model reads and writes. Four decimals is
    /// 0.34 device pixels on a 3420-wide display — finer than the model can aim or read.
    static func format(_ v: CGFloat) -> String { String(format: "%.4f", Double(v)) }
}

extension ToolExecutionService {

    // MARK: - Screen lookup

    @MainActor
    static func screen(at index: Int) -> NSScreen? {
        let screens = NSScreen.screens
        guard index >= 0, index < screens.count else { return nil }
        return screens[index]
    }

    @MainActor
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? CGDirectDisplayID ?? CGMainDisplayID()
    }

    // MARK: - Capture with real cursor (SCScreenshotManager, macOS 14+)

    /// Captures the display including the real system cursor.
    /// Falls back to CGDisplayCreateImage (no cursor) on older OS or if SC permission is denied.
    /// NOT @MainActor — SCScreenshotManager completes on a background thread and must not
    /// try to re-enter the main actor, which would deadlock if the caller holds it.
    static func captureWithCursor(displayID: CGDirectDisplayID) async -> CGImage? {
        if #available(macOS 14.0, *) {
            if let img = await Self.captureViaSC(displayID: displayID) { return img }
        }
        // Fallback: cursor-free capture so the tool still works.
        return CGDisplayCreateImage(displayID)
    }

    @available(macOS 14.0, *)
    private static func captureViaSC(displayID: CGDirectDisplayID) async -> CGImage? {
        // Find the SCDisplay matching this CGDirectDisplayID.
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false,
                                                                                   onScreenWindowsOnly: false),
              let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            return nil
        }
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        // Without explicit size SCKit may capture at a default size and distort the aspect ratio.
        let pixelScale = CGFloat(filter.pointPixelScale)
        config.width = Int((CGFloat(scDisplay.width) * pixelScale).rounded())
        config.height = Int((CGFloat(scDisplay.height) * pixelScale).rounded())
        config.capturesShadowsOnly = false
        config.showsCursor = true             // real cursor baked in by the system
        config.colorSpaceName = CGColorSpace.sRGB as CFString
        config.pixelFormat = kCVPixelFormatType_32BGRA
        return try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                           configuration: config)
    }

    // MARK: - Downscale to picture size

    /// Downscales the native capture to the picture size defined by MonitorMapping.
    @MainActor
    static func renderPicture(_ full: CGImage, mapping: MonitorMapping) -> NSBitmapImageRep? {
        let w = max(1, Int(mapping.pictureSize.width))
        let h = max(1, Int(mapping.pictureSize.height))
        guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: w, pixelsHigh: h,
                bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        bitmap.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        graphics.cgContext.interpolationQuality = .high
        graphics.cgContext.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
        return bitmap
    }

    // MARK: - Shared result builder

    /// Captures the monitor, encodes the picture as JPEG, and assembles the ToolImageResult.
    /// `cursorEventPt`: the current cursor position in CGEvent coordinates.
    @MainActor
    static func buildOverviewResult(
        screen: NSScreen,
        monitorIndex: Int,
        monitorCount: Int,
        full: CGImage,
        cursorEventPt: CGPoint,
        extraText: String = ""
    ) -> String {
        let bounds = CGDisplayBounds(Self.displayID(of: screen))
        let mapping = MonitorMapping(
            displayBounds: bounds,
            nativeSize: CGSize(width: full.width, height: full.height)
        )
        guard let bitmap = Self.renderPicture(full, mapping: mapping),
              let jpeg = bitmap.representation(using: .jpeg,
                                               properties: [.compressionFactor: 0.7]) else {
            return "❌ computer_screenshot: Failed to render monitor \(monitorIndex)."
        }
        let cursor = mapping.toFraction(cursorEventPt)
        let text = "Monitor \(monitorIndex) of \(monitorCount) (indexes 0...\(monitorCount - 1)). "
            + "Cursor tip at x=\(MonitorMapping.format(cursor.x)), y=\(MonitorMapping.format(cursor.y)). "
            + "ALL coordinates are FRACTIONS of the monitor, 0...1, (0,0) = top-left, 1 = the far edge. "
            + "Fractions hold at any image scale, so read a position as a share of the picture. "
            + "Info only, not for aiming: picture sent \(bitmap.pixelsWide)×\(bitmap.pixelsHigh) px, "
            + "screen \(full.width)×\(full.height) device px. "
            + "To move: computer_move_to(x,y), or computer_move_by(dx,dy) with a small fractional delta. "
            + "To click: computer_click (clicks the current cursor position)."
            + (extraText.isEmpty ? "" : "\n\n" + extraText)
        return ToolImageResult(
            text: text,
            images: [.init(label: "Monitor \(monitorIndex) of \(monitorCount).",
                           dataURI: "data:image/jpeg;base64,\(jpeg.base64EncodedString())")]
        ).encoded()
    }
}
