// ComputerUseMarksTests.swift
// ChappieCoreTests
//
// The numbered-box layer for Computer Use. What matters here is not cosmetics: a box drawn in the
// wrong quadrant would point the model at the wrong half of the screen, and the click would be
// wrong in exactly the same way. Orientation and the points→pixels chain are therefore tested
// against real rendered pixels, not against arithmetic alone.

import Testing
import Foundation
import CoreGraphics
import AppKit
@testable import ChappieCore

// MARK: - Helpers

/// Flat grey: anything cyan in the output can only have been painted by the marks layer.
private func greyImage(width: Int = 2880, height: Int = 1800) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

/// Counts cyan pixels in a rectangle given in image pixels, y measured from the top.
private func cyanPixels(_ rep: NSBitmapImageRep, in rect: CGRect) -> Int {
    let x0 = max(0, Int(rect.minX)), x1 = min(rep.pixelsWide, Int(rect.maxX))
    let y0 = max(0, Int(rect.minY)), y1 = min(rep.pixelsHigh, Int(rect.maxY))
    guard x1 > x0, y1 > y0 else { return 0 }
    var count = 0
    for y in y0..<y1 {
        for x in x0..<x1 {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if color.blueComponent > 0.60, color.greenComponent > 0.55,
               color.redComponent < 0.45 {
                count += 1
            }
        }
    }
    return count
}

private func element(_ role: String, _ title: String, _ frame: CGRect) -> AccessibleElement {
    AccessibleElement(role: role, title: title, frame: frame)
}

// MARK: - Transform

@Suite("Display transform")
struct DisplayTransformTests {

    /// 2880×1800 device pixels on a 1440×900 point display: backing 2, overview scale 0.5,
    /// so points and overview pixels are numerically identical.
    private let retina = DisplayTransform(displayBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                          backingScale: 2,
                                          imageScale: 0.5)

    @Test("points map one-to-one onto the overview on a 1440×900 Retina display")
    func retinaOneToOne() {
        #expect(retina.pointsToImage == 1)
        let rect = retina.imageRect(CGRect(x: 100, y: 200, width: 30, height: 40))
        #expect(rect == CGRect(x: 100, y: 200, width: 30, height: 40))
    }

    @Test("a control in the bottom-right corner stays in the bottom-right corner")
    func cornerPreserved() {
        let rect = retina.imageRect(CGRect(x: 1400, y: 860, width: 40, height: 40))
        #expect(rect.maxX == 1440)
        #expect(rect.maxY == 900)
    }

    @Test("a secondary display's global origin is removed")
    func secondaryDisplayOffset() {
        let second = DisplayTransform(displayBounds: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                                      backingScale: 2,
                                      imageScale: 0.5)
        let rect = second.imageRect(CGRect(x: 1540, y: 100, width: 20, height: 20))
        #expect(rect == CGRect(x: 100, y: 100, width: 20, height: 20))
    }

    @Test("a 1x display with a downscaled overview halves the coordinates")
    func nonRetinaHalved() {
        let plain = DisplayTransform(displayBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                     backingScale: 1,
                                     imageScale: 0.5)
        let rect = plain.imageRect(CGRect(x: 200, y: 100, width: 40, height: 20))
        #expect(rect == CGRect(x: 100, y: 50, width: 20, height: 10))
    }

    @Test("the centre of a control maps to the centre of its box")
    func centreMapsToCentre() {
        let axFrame = CGRect(x: 300, y: 400, width: 60, height: 20)
        let rect = retina.imageRect(axFrame)
        #expect(rect.midX == axFrame.midX)
        #expect(rect.midY == axFrame.midY)
    }
}

// MARK: - Layout

@Suite("Element marks layout")
struct ElementMarksLayoutTests {

    private let retina = DisplayTransform(displayBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                          backingScale: 2,
                                          imageScale: 0.5)
    private let overview = CGSize(width: 1440, height: 900)

    @Test("numbers start at 1 and follow reading order")
    func numbering() {
        let elements = [
            element("AXButton", "Close", CGRect(x: 10, y: 10, width: 20, height: 20)),
            element("AXButton", "Save",  CGRect(x: 60, y: 10, width: 40, height: 20)),
            element("AXTextField", "Search", CGRect(x: 10, y: 60, width: 200, height: 24))
        ]
        let marks = ElementMarks.layout(elements, transform: retina, overviewSize: overview)
        #expect(marks.map(\.number) == [1, 2, 3])
        #expect(marks.map(\.element.title) == ["Close", "Save", "Search"])
    }

    @Test("a control outside the captured display is dropped, and numbering stays contiguous")
    func offscreenDropped() {
        let elements = [
            element("AXButton", "A", CGRect(x: 10, y: 10, width: 20, height: 20)),
            element("AXButton", "Off", CGRect(x: 2000, y: 10, width: 20, height: 20)),
            element("AXButton", "B", CGRect(x: 60, y: 10, width: 20, height: 20))
        ]
        let marks = ElementMarks.layout(elements, transform: retina, overviewSize: overview)
        #expect(marks.map(\.number) == [1, 2])
        #expect(marks.map(\.element.title) == ["A", "B"])
    }

    @Test("a sub-pixel control gets no box")
    func hairlineDropped() {
        let elements = [element("AXHandle", "divider", CGRect(x: 10, y: 10, width: 0.2, height: 30))]
        let tiny = DisplayTransform(displayBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                    backingScale: 1, imageScale: 0.25)
        #expect(ElementMarks.layout(elements, transform: tiny, overviewSize: overview).isEmpty)
    }

    @Test("the list is capped even when the tree is huge")
    func capped() {
        let elements = (0..<120).map {
            element("AXButton", "b\($0)", CGRect(x: CGFloat($0) * 5, y: 100, width: 4, height: 4))
        }
        let marks = ElementMarks.layout(elements, transform: retina,
                                        overviewSize: overview, limit: 10)
        #expect(marks.count == 10)
        #expect(marks.last?.number == 10)
    }

    @Test("badges of adjacent icon buttons are pushed apart instead of piled up")
    func badgesDoNotCollide() {
        let boxes = (0..<4).map { CGRect(x: CGFloat($0) * 8, y: 100, width: 10, height: 10) }
        let rects = ElementMarks.badgeRects(boxes: boxes,
                                            badgeSize: CGSize(width: 14, height: 14),
                                            outSize: CGSize(width: 400, height: 300))
        #expect(rects.count == 4)
        for i in rects.indices {
            for j in rects.indices where j > i {
                #expect(!rects[i].intersects(rects[j]), "badges \(i + 1) and \(j + 1) overlap")
            }
        }
    }

    @Test("a badge never leaves the picture, even for a box against the top edge")
    func badgeStaysInside() throws {
        let outSize = CGSize(width: 400, height: 300)
        let boxes = [CGRect(x: 10, y: 290, width: 10, height: 10)]   // flush with the top
        let rects = ElementMarks.badgeRects(boxes: boxes,
                                            badgeSize: CGSize(width: 14, height: 14),
                                            outSize: outSize)
        let badge = try #require(rects.first)
        #expect(badge.minY >= 0)
        #expect(badge.maxY <= outSize.height)
        #expect(badge.minX >= 0)
        #expect(badge.maxX <= outSize.width)
    }

    @Test("the text list names role, title and size")
    func listText() {
        let marks = ElementMarks.layout(
            [element("AXButton", "Close", CGRect(x: 10, y: 10, width: 12, height: 12)),
             element("AXButton", "", CGRect(x: 40, y: 10, width: 12, height: 12))],
            transform: retina, overviewSize: overview)
        let text = ElementMarks.listText(marks)
        #expect(text.contains("[1] AXButton \"Close\" 12×12"))
        #expect(text.contains("[2] AXButton \"(untitled)\" 12×12"))
        #expect(text.split(separator: "\n").count == 2)
    }
}

// MARK: - Drawing

@Suite("Element marks drawing")
@MainActor
struct ElementMarksDrawingTests {

    /// Points and overview pixels coincide here: box (100,100,60,60) is the top-left quadrant.
    private var retina: DisplayTransform {
        DisplayTransform(displayBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
                         backingScale: 2, imageScale: 0.5)
    }

    @Test("a box is painted where its control is, not mirrored")
    func orientation() throws {
        let marks = ElementMarks.layout(
            [element("AXButton", "TopLeft", CGRect(x: 100, y: 100, width: 60, height: 60))],
            transform: retina, overviewSize: CGSize(width: 1440, height: 900))
        let rep = try #require(ToolExecutionService.renderScreenshot(
            greyImage(), region: nil, grid: false, marks: marks))

        let here = CGRect(x: 85, y: 85, width: 100, height: 100)
        let mirrored = CGRect(x: 85, y: 715, width: 100, height: 100)
        #expect(cyanPixels(rep, in: here) > 100, "the box must appear in the top-left quadrant")
        #expect(cyanPixels(rep, in: mirrored) == 0, "nothing may appear in the mirrored quadrant")
    }

    @Test("a box in the bottom-right quadrant lands there")
    func bottomRight() throws {
        let marks = ElementMarks.layout(
            [element("AXButton", "BottomRight", CGRect(x: 1300, y: 800, width: 80, height: 40))],
            transform: retina, overviewSize: CGSize(width: 1440, height: 900))
        let rep = try #require(ToolExecutionService.renderScreenshot(
            greyImage(), region: nil, grid: false, marks: marks))

        let here = CGRect(x: 1240, y: 760, width: 200, height: 140)
        let mirrored = CGRect(x: 1240, y: 0, width: 200, height: 140)
        #expect(cyanPixels(rep, in: here) > 50)
        #expect(cyanPixels(rep, in: mirrored) == 0)
    }

    @Test("a zoomed view keeps the box on its control, magnified")
    func zoomKeepsBox() throws {
        let marks = ElementMarks.layout(
            [element("AXButton", "Close", CGRect(x: 20, y: 20, width: 12, height: 12))],
            transform: retina, overviewSize: CGSize(width: 1440, height: 900))
        let region = CGRect(x: 0, y: 0, width: 100, height: 100)
        let rep = try #require(ToolExecutionService.renderScreenshot(
            greyImage(), region: region, grid: false, marks: marks))

        // The 100×100 overview region is delivered at 200×200 device pixels.
        #expect(rep.pixelsWide == 200)
        // Control centre is image (26,26) → 52 % across and down the zoomed picture.
        let centre = CGRect(x: 40, y: 40, width: 40, height: 40)
        #expect(cyanPixels(rep, in: centre) > 0)
        let farCorner = CGRect(x: 150, y: 150, width: 40, height: 40)
        #expect(cyanPixels(rep, in: farCorner) == 0)
    }

    @Test("marks and grid coexist without erasing each other")
    func marksAndGrid() throws {
        let marks = ElementMarks.layout(
            [element("AXButton", "Close", CGRect(x: 200, y: 200, width: 40, height: 40))],
            transform: retina, overviewSize: CGSize(width: 1440, height: 900))
        let plain = try #require(ToolExecutionService.renderScreenshot(
            greyImage(), region: nil, grid: true, marks: []))
        let both = try #require(ToolExecutionService.renderScreenshot(
            greyImage(), region: nil, grid: true, marks: marks))
        let boxArea = CGRect(x: 190, y: 190, width: 60, height: 60)
        #expect(cyanPixels(plain, in: boxArea) == 0)
        #expect(cyanPixels(both, in: boxArea) > 20)
    }

    @Test("an empty mark list leaves the picture untouched")
    func noMarksNoChange() throws {
        let plain = try #require(ToolExecutionService.renderScreenshot(
            greyImage(), region: nil, grid: false, marks: []))
        #expect(cyanPixels(plain, in: CGRect(x: 0, y: 0, width: 1440, height: 900)) == 0)
    }
}
