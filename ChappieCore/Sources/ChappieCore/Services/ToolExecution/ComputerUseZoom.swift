// ComputerUseZoom.swift
// ChappieCore
//
// WHY THIS FILE:
// computer_zoom is the magnifier. The overview frame is capped at 1440 px, so on a Retina display a
// 10 pt disclosure chevron lands on about two pixels — the model cannot read it and cannot aim at
// it. Zoom returns a 1:1 native crop around a point: small enough to cost almost nothing in tokens,
// and honest about its own corners, so the model converts what it sees back into aiming coordinates
// by arithmetic on exact numbers instead of guessing on a shrunken picture.
//
// ONE COORDINATE SYSTEM STILL. The crop does NOT introduce a second one: its edges are given as
// monitor fractions, and the model is told, in the result text, to interpolate between them. A
// position inside the crop is never a coordinate in its own right.

import Foundation
import CoreGraphics
import AppKit

extension MonitorMapping {

    /// Smallest useful crop: about 34 device px across on a 3420-wide display (17 pt).
    static let minZoomSpan: CGFloat = 0.005
    /// Largest span the model may ask for. Anything wider is a second overview, not a magnifier.
    static let maxZoomSpan: CGFloat = 0.25

    /// Longest span whose crop still fits under `overviewMaxSide`. A larger crop would be silently
    /// resized on its way to the provider — which is the exact uncertainty zoom exists to remove.
    var maxUsableZoomSpan: CGFloat {
        let longest = max(nativeSize.width, nativeSize.height, 1)
        return min(MonitorMapping.maxZoomSpan, MonitorMapping.overviewMaxSide / (2 * longest))
    }

    /// Keeps a requested span inside the useful range and under the picture cap.
    func clampZoomSpan(_ requested: CGFloat) -> CGFloat {
        guard !requested.isNaN else { return 0.05 }
        return min(max(requested, MonitorMapping.minZoomSpan), maxUsableZoomSpan)
    }

    /// Crop rectangle in device pixels (top-left origin of the image, y downward) for a span
    /// around a fraction of the monitor. The size is kept and the rectangle is slid inside the
    /// display instead of being shrunk, so a crop near an edge shows the same area, just off-centre.
    func cropRect(span requested: CGFloat, around center: CGPoint) -> CGRect {
        let w = max(nativeSize.width, 1)
        let h = max(nativeSize.height, 1)
        let span = clampZoomSpan(requested)

        let sizeW = min(span * 2 * w, w)
        let sizeH = min(span * 2 * h, h)
        let cx = MonitorMapping.unit(center.x) * w
        let cy = MonitorMapping.unit(center.y) * h

        let x0 = min(max(cx - sizeW / 2, 0), w - sizeW)
        let y0 = min(max(cy - sizeH / 2, 0), h - sizeH)
        let ix = x0.rounded(.down)
        let iy = y0.rounded(.down)

        return CGRect(
            x: ix,
            y: iy,
            width:  max(1, min(sizeW.rounded(), w - ix)),
            height: max(1, min(sizeH.rounded(), h - iy))
        )
    }
}

extension ToolExecutionService {

    /// Captures the monitor and returns a native crop around the current cursor position.
    @MainActor
    static func zoomScreenshot(monitor: Int, span: CGFloat, center: CGPoint?) async -> String {
        let count = NSScreen.screens.count
        guard let screen = Self.screen(at: monitor) else {
            return "❌ computer_zoom: Monitor \(monitor) not found. Connected monitors: \(count)."
        }
        let dispID = Self.displayID(of: screen)
        guard let full = await Self.captureWithCursor(displayID: dispID) else {
            return "❌ computer_zoom: Failed to capture monitor \(monitor)."
        }
        return Self.buildZoomResult(
            screen: screen,
            monitorIndex: monitor,
            monitorCount: count,
            full: full,
            cursorEventPt: Self.currentCursorPosition(),
            span: span,
            center: center
        )
    }

    /// Crops the native capture around `center` (or the cursor) and returns the picture plus the
    /// crop's own edges as monitor fractions.
    @MainActor
    static func buildZoomResult(
        screen: NSScreen,
        monitorIndex: Int,
        monitorCount: Int,
        full: CGImage,
        cursorEventPt: CGPoint,
        span requested: CGFloat,
        center: CGPoint?
    ) -> String {
        // Build the mapping from the captured picture itself, so pixels and fractions cannot drift.
        let bounds = CGDisplayBounds(Self.displayID(of: screen))
        let mapping = MonitorMapping(
            displayBounds: bounds,
            nativeSize: CGSize(width: full.width, height: full.height)
        )
        let cursor = mapping.toFraction(cursorEventPt)
        let focus = center ?? cursor
        let rect = mapping.cropRect(span: requested, around: focus)

        guard let crop = full.cropping(to: rect) else {
            return "❌ computer_zoom: Could not crop monitor \(monitorIndex) at "
                + "x=\(MonitorMapping.format(focus.x)), y=\(MonitorMapping.format(focus.y))."
        }
        let bitmap = NSBitmapImageRep(cgImage: crop)
        guard let jpeg = bitmap.representation(using: .jpeg,
                                               properties: [.compressionFactor: 0.85]) else {
            return "❌ computer_zoom: Failed to encode the crop on monitor \(monitorIndex)."
        }

        let nw = max(CGFloat(full.width), 1)
        let nh = max(CGFloat(full.height), 1)
        let left   = rect.minX / nw
        let right  = rect.maxX / nw
        let top    = rect.minY / nh
        let bottom = rect.maxY / nh

        var text = "Zoom on monitor \(monitorIndex) of \(monitorCount). Native crop 1:1, no downscale. "
            + "crop x \(MonitorMapping.format(left))–\(MonitorMapping.format(right)), "
            + "y \(MonitorMapping.format(top))–\(MonitorMapping.format(bottom)) as FRACTIONS of the MONITOR. "
            + "cursor \(MonitorMapping.format(cursor.x)), \(MonitorMapping.format(cursor.y)). "
            + "picture \(crop.width)x\(crop.height) device px. "
            + "Aim with monitor fractions, never with a position inside this crop: "
            + "monitor fraction = low edge + share inside the crop × (high edge − low edge)."

        let effective = mapping.clampZoomSpan(requested)
        if !requested.isNaN, effective > requested {
            text += " Span raised from \(MonitorMapping.format(requested)) to "
                + "\(MonitorMapping.format(effective)) to stay readable."
        } else if !requested.isNaN, effective < requested {
            text += " Span reduced from \(MonitorMapping.format(requested)) to "
                + "\(MonitorMapping.format(effective)) to stay under the picture size cap."
        }

        return ToolImageResult(
            text: text,
            images: [.init(label: "Zoom \(crop.width)x\(crop.height) around the cursor.",
                           dataURI: "data:image/jpeg;base64,\(jpeg.base64EncodedString())")]
        ).encoded()
    }
}
