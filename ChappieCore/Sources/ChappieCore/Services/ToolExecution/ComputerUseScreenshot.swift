// ComputerUseScreenshot.swift
// ChappieCore
//
// WHY THIS FILE:
// Screen capture shared by all computer tools. Uses SCScreenshotManager so the system draws
// the real cursor into the image — the cursor's shape, position, and hotspot are always truthful.
// MonitorMapping translates between picture pixels (what the model sees) and CGEvent space
// (what the OS uses for mouse coordinates) so the model never has to convert anything itself.

import Foundation
import CoreGraphics
import AppKit
import ScreenCaptureKit

/// Translates between the compressed picture the model sees and CGEvent screen coordinates.
///
/// The model works entirely in picture pixels. `toEvent` converts a picture point to the
/// CGEvent coordinate, `toPicture` goes the other way. The model never needs to know the
/// native resolution or the Retina scale factor.
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

    /// Picture pixel → CGEvent point (top-left origin across all displays).
    func toEvent(_ picturePt: CGPoint) -> CGPoint {
        let nx = (picturePt.x / scale).rounded()
        let ny = (picturePt.y / scale).rounded()
        // Native pixels are top-left relative to this display's capture origin.
        // CGDisplayBounds gives the display rect in CGEvent space (top-left of main display).
        let fx = nx / max(nativeSize.width, 1)
        let fy = ny / max(nativeSize.height, 1)
        return CGPoint(
            x: displayBounds.minX + fx * displayBounds.width,
            y: displayBounds.minY + fy * displayBounds.height
        )
    }

    /// CGEvent point → picture pixel (clamped to the picture).
    func toPicture(_ eventPt: CGPoint) -> CGPoint {
        let fx = (eventPt.x - displayBounds.minX) / max(displayBounds.width, 1)
        let fy = (eventPt.y - displayBounds.minY) / max(displayBounds.height, 1)
        let px = (fx * nativeSize.width  * scale).rounded()
        let py = (fy * nativeSize.height * scale).rounded()
        return CGPoint(
            x: min(max(px, 0), pictureSize.width  - 1),
            y: min(max(py, 0), pictureSize.height - 1)
        )
    }
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
        cursorEventPt: CGPoint
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
        let cursorPic = mapping.toPicture(cursorEventPt)
        let pw = bitmap.pixelsWide
        let ph = bitmap.pixelsHigh
        let text = "Monitor \(monitorIndex) of \(monitorCount) (indexes 0...\(monitorCount - 1)). "
            + "Picture: \(pw)×\(ph) px. "
            + "Cursor at (\(Int(cursorPic.x.rounded())), \(Int(cursorPic.y.rounded()))) in picture pixels. "
            + "All coordinates use picture pixels (0,0 = top-left). "
            + "To move cursor: computer_move_to(x,y) for a new position, computer_move_by(dx,dy) to nudge. "
            + "To click: computer_click (clicks current cursor position)."
        return ToolImageResult(
            text: text,
            images: [.init(label: "Monitor \(monitorIndex) of \(monitorCount).",
                           dataURI: "data:image/jpeg;base64,\(jpeg.base64EncodedString())")]
        ).encoded()
    }
}
