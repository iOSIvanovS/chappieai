// ComputerUseOverview.swift
// ChappieCore
//
// WHY THIS FILE:
// The clean overview for computer_screenshot: one whole monitor, untouched, plus the monitor
// count so the model knows what else it can look at. The only thing ever drawn on it is the
// optional coarse grid, and that grid is in fractions of the picture (0.1 ... 0.9) because those
// are the units computer_aim takes. Precision comes from computer_aim, not from this picture.

import Foundation
import CoreGraphics
import AppKit

extension ToolExecutionService {

    /// Distance between grid lines as a fraction of the monitor image: 10x10 cells.
    static let overviewGridStep: CGFloat = 0.1

    /// A whole monitor as text plus one picture.
    /// - Parameters:
    ///   - monitor: zero-based monitor index.
    ///   - grid: draw the coarse fraction grid. Off by default so the model sees the true screen.
    @MainActor
    static func overviewScreenshot(monitor: Int, grid: Bool) -> String {
        let count = NSScreen.screens.count
        guard let screen = Self.screen(at: monitor) else {
            return "❌ computer_screenshot: Monitor \(monitor) not found. Connected monitors: \(count)."
        }
        guard let full = Self.captureDisplay(screen) else {
            return "❌ computer_screenshot: Failed to capture monitor \(monitor)."
        }
        guard let bitmap = Self.renderScreenshot(full, region: nil, grid: false) else {
            return "❌ computer_screenshot: Failed to render monitor \(monitor)."
        }
        if grid { Self.drawFractionGrid(on: bitmap) }
        guard let jpeg = bitmap.representation(using: .jpeg,
                                               properties: [.compressionFactor: 0.7]) else {
            return "❌ computer_screenshot: Failed to encode screenshot."
        }

        let text = "Monitor \(monitor) of \(count) connected (indexes 0...\(count - 1)), "
            + "image \(bitmap.pixelsWide)x\(bitmap.pixelsHigh). "
            + (grid ? "Grid lines are labelled with fractions of the image. " : "")
            + "To click, call computer_aim with x and y as fractions 0...1 of this image, "
            + "check the crosshair, then call computer_click."
        return ToolImageResult(
            text: text,
            images: [.init(label: "Monitor \(monitor) of \(count)" + (grid ? ", grid step 0.1." : "."),
                           dataURI: "data:image/jpeg;base64,\(jpeg.base64EncodedString())")]
        ).encoded()
    }

    // MARK: - Grid

    /// Coarse grid over a finished picture. Thin translucent lines keep the content readable;
    /// labels sit on the top and left edges so they do not cover the middle of the screen.
    @MainActor
    static func drawFractionGrid(on bitmap: NSBitmapImageRep) {
        guard let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        let w = CGFloat(bitmap.pixelsWide)
        let h = CGFloat(bitmap.pixelsHigh)
        let steps = Int((1 / overviewGridStep).rounded()) - 1

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        let cg = graphics.cgContext

        // The context origin is bottom-left, so a fraction measured from the top is flipped here.
        func lineX(_ i: Int) -> CGFloat { (w * CGFloat(i) * overviewGridStep).rounded() + 0.5 }
        func lineY(_ i: Int) -> CGFloat { h - (h * CGFloat(i) * overviewGridStep).rounded() - 0.5 }

        cg.setStrokeColor(NSColor(srgbRed: 1, green: 0.16, blue: 0.55, alpha: 0.4).cgColor)
        cg.setLineWidth(1)
        for i in 1...steps {
            cg.move(to: CGPoint(x: lineX(i), y: 0));  cg.addLine(to: CGPoint(x: lineX(i), y: h))
            cg.move(to: CGPoint(x: 0, y: lineY(i)));  cg.addLine(to: CGPoint(x: w, y: lineY(i)))
        }
        cg.strokePath()

        let fontSize = max(11, min(18, w / 120))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.white
        ]
        func label(_ text: String, at point: CGPoint) {
            let size = (text as NSString).size(withAttributes: attrs)
            let p = CGPoint(x: min(max(point.x, 2), w - size.width - 2),
                            y: min(max(point.y, 2), h - size.height - 2))
            cg.setFillColor(NSColor(white: 0, alpha: 0.55).cgColor)
            cg.fill(CGRect(x: p.x - 2, y: p.y - 1, width: size.width + 4, height: size.height + 2))
            (text as NSString).draw(at: p, withAttributes: attrs)
        }
        for i in 1...steps {
            let text = String(format: "%.1f", CGFloat(i) * overviewGridStep)
            label(text, at: CGPoint(x: lineX(i) + 3, y: h - fontSize - 6))
            label(text, at: CGPoint(x: 4, y: lineY(i) + 2))
        }
    }
}
