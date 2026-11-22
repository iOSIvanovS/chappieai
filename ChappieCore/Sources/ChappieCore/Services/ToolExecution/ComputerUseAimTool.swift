// ComputerUseAimTool.swift
// ChappieCore
//
// WHY THIS FILE:
// Rendering and execution of computer_aim. The crop is delivered at native resolution with a
// crosshair whose intersection is the exact click point, so the model can judge the hit before
// it commits. Geometry and the pending-aim state live in ComputerUseAim.swift.

import Foundation
import CoreGraphics
import AppKit

extension ToolExecutionService {

    /// The one pending aim, consumed by computer_click.
    static let aimStore = AimStore()

    /// Arguments of computer_aim: fractions 0...1 of the monitor image.
    private struct AimArguments: Decodable {
        var x: FlexDouble?
        var y: FlexDouble?
        var monitor: FlexInt?
    }

    // MARK: - Execution

    func performAim(argsData: Data) async -> String {
        let rawJSON = String(data: argsData, encoding: .utf8) ?? "<non-utf8>"
        guard let args = try? JSONDecoder().decode(AimArguments.self, from: argsData),
              let x = args.x?.value, let y = args.y?.value else {
            return "❌ computer_aim: 'x' and 'y' are required, as fractions from 0 to 1 of the monitor image. Raw args: \(rawJSON)"
        }
        let monitor = args.monitor?.value ?? 0
        return await MainActor.run {
            Self.aim(fractionX: x, fractionY: y, monitor: monitor)
        }
    }

    @MainActor
    static func aim(fractionX: Double, fractionY: Double, monitor: Int) -> String {
        guard let screen = Self.screen(at: monitor) else {
            return "❌ computer_aim: Monitor \(monitor) not found. Connected monitors: \(NSScreen.screens.count)."
        }
        guard let full = Self.captureDisplay(screen) else {
            return "❌ computer_aim: Failed to capture monitor \(monitor)."
        }
        let geometry = AimGeometry(
            fraction: CGPoint(x: fractionX, y: fractionY),
            monitor: monitor,
            displayBounds: CGDisplayBounds(Self.displayID(of: screen)),
            nativeSize: CGSize(width: full.width, height: full.height))

        guard let bitmap = Self.renderAim(full, geometry: geometry),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return "❌ computer_aim: Failed to render the aim crop."
        }
        // The new aim replaces any earlier one; only now that rendering worked is it armed.
        Self.aimStore.set(geometry.aimPoint)

        let f = geometry.fraction
        let text = String(format: "Aimed at x=%.4f y=%.4f of monitor %d (screen point %d, %d). "
                          + "The crosshair gap marks the exact click point. If it is on the target, call computer_click; "
                          + "otherwise call computer_aim again with corrected fractions.",
                          f.x, f.y, monitor,
                          Int(geometry.eventPoint.x.rounded()), Int(geometry.eventPoint.y.rounded()))
        return ToolImageResult(
            text: text,
            images: [.init(label: "Aim crop, monitor \(monitor), native resolution.",
                           dataURI: "data:image/jpeg;base64,\(jpeg.base64EncodedString())")]
        ).encoded()
    }

    // MARK: - Rendering

    /// Native-resolution crop with a crosshair. The lines leave a small gap at the intersection so
    /// the pixel being aimed at stays visible instead of being painted over.
    @MainActor
    static func renderAim(_ full: CGImage, geometry: AimGeometry) -> NSBitmapImageRep? {
        guard let crop = full.cropping(to: geometry.cropPixels) else { return nil }
        let w = crop.width
        let h = crop.height

        // Explicit bitmap rep keeps the output at exactly w×h pixels on Retina displays.
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
        NSGraphicsContext.current = graphics
        let cg = graphics.cgContext
        cg.interpolationQuality = .none
        cg.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))

        // The context origin is bottom-left; the crosshair position is top-left based.
        let c = geometry.crosshairInCrop
        let cx = c.x.rounded() + 0.5
        let cy = CGFloat(h) - c.y.rounded() - 0.5
        let gap: CGFloat = 5

        // Dark underlay plus bright line stays visible on both light and dark interfaces.
        func segments(color: NSColor, width: CGFloat) {
            cg.setStrokeColor(color.cgColor)
            cg.setLineWidth(width)
            cg.move(to: CGPoint(x: 0, y: cy));            cg.addLine(to: CGPoint(x: cx - gap, y: cy))
            cg.move(to: CGPoint(x: cx + gap, y: cy));     cg.addLine(to: CGPoint(x: CGFloat(w), y: cy))
            cg.move(to: CGPoint(x: cx, y: 0));            cg.addLine(to: CGPoint(x: cx, y: cy - gap))
            cg.move(to: CGPoint(x: cx, y: cy + gap));     cg.addLine(to: CGPoint(x: cx, y: CGFloat(h)))
            cg.strokePath()
        }
        segments(color: NSColor(white: 0, alpha: 0.55), width: 3)
        segments(color: NSColor(srgbRed: 1, green: 0.16, blue: 0.55, alpha: 0.95), width: 1)

        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
}
