// ComputerUseMarks.swift
// ChappieCore
//
// WHY THIS FILE:
// Turns accessibility frames into numbered boxes drawn on the screenshot, and into the numbered
// list the model reads. The model then says "click element 7" instead of guessing a pixel; the
// click itself uses the AX centre, so the box is only a visual anchor, never the hit target.
//
// THREE COORDINATE SPACES, ONE CONVERSION:
// AX frames are in points measured from the top-left corner of the primary display. The captured
// image is in native device pixels. The model reads the overview image, which is that capture
// downscaled to at most 1440 px. DisplayTransform is the single place that chain is applied, so a
// box can never drift away from the control it labels.

import Foundation
import CoreGraphics
import AppKit

// MARK: - Transform

/// AX points → overview-image pixels for one display.
struct DisplayTransform: Equatable {
    /// Display bounds in CG global coordinates (top-left origin of the primary display) — the
    /// same space accessibility frames are reported in.
    let displayBounds: CGRect
    /// Points → native device pixels: 2 on Retina, 1 on a standard display.
    let backingScale: CGFloat
    /// Native device pixels → overview image pixels.
    let imageScale: CGFloat

    /// Points → overview image pixels.
    var pointsToImage: CGFloat { backingScale * imageScale }

    func imagePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - displayBounds.minX) * pointsToImage,
                y: (point.y - displayBounds.minY) * pointsToImage)
    }

    /// A secondary display starts at a non-zero global origin, so the offset is removed here.
    func imageRect(_ rect: CGRect) -> CGRect {
        let origin = imagePoint(rect.origin)
        return CGRect(x: origin.x, y: origin.y,
                      width: rect.width * pointsToImage,
                      height: rect.height * pointsToImage)
    }
}

// MARK: - Mark

/// One numbered box: what it labels, and where it sits on the overview image.
struct ElementMark: Equatable, Sendable {
    /// 1-based, and this is the number the model passes back to computer_click.
    let number: Int
    let element: AccessibleElement
    /// Box in overview-image pixels.
    let imageRect: CGRect

    /// The line the model reads in the element list. Size is in AX points, as macOS reports it.
    var listLine: String {
        let name = element.title.isEmpty ? "(untitled)" : element.title
        return "[\(number)] \(element.role) \"\(name)\" \(Int(element.frame.width.rounded()))"
            + "×\(Int(element.frame.height.rounded()))"
    }
}

// MARK: - Layout

enum ElementMarks {

    /// Numbers the elements in the order they were selected (reading order) and drops anything
    /// that falls outside the captured display.
    static func layout(_ elements: [AccessibleElement],
                       transform: DisplayTransform,
                       overviewSize: CGSize,
                       limit: Int = AccessibilitySelection.defaultLimit) -> [ElementMark] {
        let overview = CGRect(origin: .zero, size: overviewSize)
        var marks: [ElementMark] = []
        for element in elements {
            guard marks.count < limit else { break }
            let rect = transform.imageRect(element.frame)
            // Sub-pixel controls cannot be pointed at even with an exact frame; the AX centre
            // still works, but a box that small carries no information.
            guard rect.width >= 0.5, rect.height >= 0.5 else { continue }
            // A window can hang off the display; only boxes with some overlap are worth showing.
            guard rect.intersects(overview) else { continue }
            marks.append(ElementMark(number: marks.count + 1, element: element, imageRect: rect))
        }
        return marks
    }

    /// The text block that accompanies the annotated picture.
    static func listText(_ marks: [ElementMark]) -> String {
        marks.map(\.listLine).joined(separator: "\n")
    }

    /// The marks inside a captured area — the one predicate both the drawing and the text list use,
    /// so the numbers on the picture and the numbers in the list can never disagree.
    static func visible(_ marks: [ElementMark], in covered: CGRect) -> [ElementMark] {
        marks.filter { $0.imageRect.intersects(covered) }
    }

    /// One badge rectangle per box, in output pixels, in the same order as `boxes`.
    /// Badges sit just above their box; a badge that would land on an earlier one is nudged
    /// upward, because a toolbar row of adjacent icon buttons otherwise piles numbers into an
    /// unreadable heap right where the model needs to tell them apart.
    static func badgeRects(boxes: [CGRect],
                           badgeSize: CGSize,
                           outSize: CGSize,
                           maxTries: Int = 4) -> [CGRect] {
        var placed: [CGRect] = []
        for box in boxes {
            var rect = CGRect(x: box.minX, y: box.maxY + 1,
                              width: badgeSize.width, height: badgeSize.height)
            var tries = 0
            while tries < maxTries, placed.contains(where: { $0.intersects(rect) }) {
                rect.origin.y += badgeSize.height + 1
                tries += 1
            }
            // Nothing above any more: drop below the box instead of leaving the picture.
            if rect.maxY > outSize.height { rect.origin.y = box.minY - badgeSize.height - 1 }
            rect.origin.x = min(max(rect.origin.x, 0), max(0, outSize.width - badgeSize.width))
            rect.origin.y = min(max(rect.origin.y, 0), max(0, outSize.height - badgeSize.height))
            placed.append(rect)
        }
        return placed
    }

    // MARK: Drawing

    private static let boxColor = NSColor(srgbRed: 0.10, green: 0.85, blue: 1.00, alpha: 0.95)
    private static let badgeColor = NSColor(srgbRed: 0.10, green: 0.85, blue: 1.00, alpha: 0.95)

    /// Draws the boxes over a rendered screenshot.
    /// - Parameter covered: the part of the overview image the output currently shows, in
    ///   overview-image pixels — the same value the grid is drawn from.
    @MainActor
    static func draw(_ marks: [ElementMark],
                     on cg: CGContext,
                     outSize: CGSize,
                     covered: CGRect) {
        guard !marks.isEmpty, outSize.width > 1, outSize.height > 1 else { return }
        let pxX = outSize.width / max(covered.width, 1)
        let pxY = outSize.height / max(covered.height, 1)

        // Same mapping as the grid: overview-image y grows downward, the context grows upward.
        func outRect(_ rect: CGRect) -> CGRect {
            let maxY = outSize.height - (rect.maxY - covered.minY) * pxY
            return CGRect(x: (rect.minX - covered.minX) * pxX,
                          y: maxY,
                          width: rect.width * pxX,
                          height: rect.height * pxY)
        }

        let fontSize = max(10, min(20, outSize.width / 120))
        let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: badgeFont,
            .foregroundColor: NSColor.black
        ]

        cg.saveGState()
        cg.setLineWidth(1.5)
        cg.setStrokeColor(boxColor.cgColor)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Only the marks the current crop (a zoom) actually shows get a box and a number.
        let visible = Self.visible(marks, in: covered)
        guard !visible.isEmpty else { cg.restoreGState(); return }

        // One width for every badge so the numbers stay aligned and the layout stays testable.
        let widest = ("\(marks.count)" as NSString).size(withAttributes: textAttrs)
        let badgeSize = CGSize(width: widest.width + 6, height: widest.height + 2)
        let badges = badgeRects(boxes: visible.map { outRect($0.imageRect) },
                                badgeSize: badgeSize,
                                outSize: outSize)

        for (index, mark) in visible.enumerated() {
            cg.stroke(outRect(mark.imageRect).insetBy(dx: -1, dy: -1))

            let text = "\(mark.number)" as NSString
            let badge = badges[index]
            cg.setFillColor(badgeColor.cgColor)
            cg.fill(badge)
            text.draw(at: CGPoint(x: badge.minX + 3, y: badge.minY + 1), withAttributes: textAttrs)
        }
        cg.restoreGState()
    }
}
