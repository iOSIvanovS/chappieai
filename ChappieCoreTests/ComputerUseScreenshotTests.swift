// ComputerUseScreenshotTests.swift
// ChappieCoreTests
//
// MonitorMapping: picture size is capped at 1440 px and never upscaled.
// toEvent / toPicture are inverse for a point inside the display.

import Testing
import Foundation
import CoreGraphics
import AppKit
@testable import ChappieCore

@Suite("MonitorMapping geometry")
struct MonitorMappingTests {

    private static let retinaBounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private static let retinaSize   = CGSize(width: 2880, height: 1800)

    @Test("A 2880×1800 capture maps to a 1440×900 picture")
    func retinaOverview() {
        let m = MonitorMapping(displayBounds: Self.retinaBounds, nativeSize: Self.retinaSize)
        #expect(m.pictureSize.width  == 1440)
        #expect(m.pictureSize.height == 900)
        #expect(m.scale == 0.5)
    }

    @Test("A capture narrower than the cap is never upscaled")
    func smallCapture() {
        let m = MonitorMapping(
            displayBounds: CGRect(x: 0, y: 0, width: 1200, height: 800),
            nativeSize: CGSize(width: 1200, height: 800))
        #expect(m.scale == 1.0)
        #expect(m.pictureSize.width  == 1200)
        #expect(m.pictureSize.height == 800)
    }

    @Test("toEvent converts the top-left corner to the display origin")
    func topLeftToEvent() {
        let m = MonitorMapping(displayBounds: Self.retinaBounds, nativeSize: Self.retinaSize)
        let pt = m.toEvent(CGPoint(x: 0, y: 0))
        #expect(pt.x == 0)
        #expect(pt.y == 0)
    }

    @Test("toEvent converts the bottom-right picture pixel to the display corner")
    func bottomRightToEvent() {
        let m = MonitorMapping(displayBounds: Self.retinaBounds, nativeSize: Self.retinaSize)
        // Last pixel of the 1440×900 picture.
        let pt = m.toEvent(CGPoint(x: 1439, y: 899))
        #expect(abs(pt.x - 1440) < 2)
        #expect(abs(pt.y - 900) < 2)
    }

    @Test("toPicture inverts toEvent for the centre point")
    func roundTrip() {
        let m = MonitorMapping(displayBounds: Self.retinaBounds, nativeSize: Self.retinaSize)
        let pic = CGPoint(x: 720, y: 450)
        let ev  = m.toEvent(pic)
        let back = m.toPicture(ev)
        #expect(abs(back.x - pic.x) < 1)
        #expect(abs(back.y - pic.y) < 1)
    }

    @Test("A second monitor offset is handled correctly")
    func secondMonitorOffset() {
        // Monitor sits to the right of the main display.
        let bounds = CGRect(x: 1440, y: 0, width: 1280, height: 800)
        let m = MonitorMapping(displayBounds: bounds, nativeSize: CGSize(width: 1280, height: 800))
        // Picture top-left should map to the display's own origin in CGEvent space.
        let ev = m.toEvent(CGPoint(x: 0, y: 0))
        #expect(ev.x == 1440)
        #expect(ev.y == 0)
    }
}

@Suite("renderPicture")
@MainActor
struct RenderPictureTests {

    private static func makeImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    @Test("A 2880×1800 image renders to 1440×900")
    func retinaRender() throws {
        let m = MonitorMapping(
            displayBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
            nativeSize: CGSize(width: 2880, height: 1800))
        let bmp = try #require(ToolExecutionService.renderPicture(Self.makeImage(width: 2880, height: 1800), mapping: m))
        #expect(bmp.pixelsWide == 1440)
        #expect(bmp.pixelsHigh == 900)
    }

    @Test("A 1200×800 image renders at 1:1")
    func smallRender() throws {
        let m = MonitorMapping(
            displayBounds: CGRect(x: 0, y: 0, width: 1200, height: 800),
            nativeSize: CGSize(width: 1200, height: 800))
        let bmp = try #require(ToolExecutionService.renderPicture(Self.makeImage(width: 1200, height: 800), mapping: m))
        #expect(bmp.pixelsWide == 1200)
        #expect(bmp.pixelsHigh == 800)
    }
}
