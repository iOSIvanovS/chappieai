// ComputerUseScreenshotTests.swift
// ChappieCoreTests
//
// MonitorMapping: picture size is capped at 1440 px and never upscaled.
// toEvent(fraction:) / toFraction are inverse for a point inside the display, and a fraction maps
// to the same screen point whatever the capture size — that independence is why the model uses it.

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

    @Test("The top-left fraction maps to the display origin")
    func topLeftToEvent() {
        let m = MonitorMapping(displayBounds: Self.retinaBounds, nativeSize: Self.retinaSize)
        let pt = m.toEvent(fraction: CGPoint(x: 0, y: 0))
        #expect(pt.x == 0)
        #expect(pt.y == 0)
    }

    @Test("The bottom-right fraction maps to the display's far corner")
    func bottomRightToEvent() {
        let m = MonitorMapping(displayBounds: Self.retinaBounds, nativeSize: Self.retinaSize)
        let pt = m.toEvent(fraction: CGPoint(x: 1, y: 1))
        #expect(pt.x == 1440)
        #expect(pt.y == 900)
    }

    @Test("The centre fraction maps to the display centre")
    func centreToEvent() {
        let m = MonitorMapping(displayBounds: Self.retinaBounds, nativeSize: Self.retinaSize)
        let pt = m.toEvent(fraction: CGPoint(x: 0.5, y: 0.5))
        #expect(pt.x == 720)
        #expect(pt.y == 450)
    }

    @Test("toFraction inverts toEvent for a point inside the display")
    func roundTrip() {
        let m = MonitorMapping(displayBounds: Self.retinaBounds, nativeSize: Self.retinaSize)
        let f  = CGPoint(x: 0.3, y: 0.7)
        let back = m.toFraction(m.toEvent(fraction: f))
        #expect(abs(back.x - f.x) < 1e-9)
        #expect(abs(back.y - f.y) < 1e-9)
    }

    @Test("A fraction is independent of the capture size")
    func fractionIgnoresCaptureSize() {
        // The whole point of fractions: the same share of the monitor lands on the same screen
        // point even though one capture is Retina and the other is not.
        let retina = MonitorMapping(displayBounds: Self.retinaBounds, nativeSize: Self.retinaSize)
        let plain  = MonitorMapping(displayBounds: Self.retinaBounds,
                                    nativeSize: CGSize(width: 1440, height: 900))
        let f = CGPoint(x: 0.25, y: 0.75)
        let a = retina.toEvent(fraction: f)
        let b = plain.toEvent(fraction: f)
        #expect(a.x == b.x)
        #expect(a.y == b.y)
    }

    @Test("Out-of-range and NaN fractions are clamped to the display")
    func clampedFraction() {
        let m = MonitorMapping(displayBounds: Self.retinaBounds, nativeSize: Self.retinaSize)
        let over = m.toEvent(fraction: CGPoint(x: 2, y: -1))
        #expect(over.x == 1440)
        #expect(over.y == 0)
        let nan = m.toEvent(fraction: CGPoint(x: CGFloat.nan, y: CGFloat.nan))
        #expect(nan.x == 720)
        #expect(nan.y == 450)
    }

    @Test("A fractional delta converts to display points")
    func deltaConversion() {
        let m = MonitorMapping(displayBounds: Self.retinaBounds, nativeSize: Self.retinaSize)
        let d = m.eventDelta(fraction: CGPoint(x: 0.01, y: -0.02))
        #expect(abs(d.x - 14.4) < 1e-9)
        #expect(abs(d.y + 18) < 1e-9)
    }

    @Test("Fractions print with four decimals")
    func formatting() {
        #expect(MonitorMapping.format(0.5) == "0.5000")
        #expect(MonitorMapping.format(0.123456) == "0.1235")
        #expect(MonitorMapping.format(0) == "0.0000")
    }

    @Test("A second monitor offset is handled correctly")
    func secondMonitorOffset() {
        // Monitor sits to the right of the main display.
        let bounds = CGRect(x: 1440, y: 0, width: 1280, height: 800)
        let m = MonitorMapping(displayBounds: bounds, nativeSize: CGSize(width: 1280, height: 800))
        // The top-left fraction should map to the second display's own origin.
        let ev = m.toEvent(fraction: CGPoint(x: 0, y: 0))
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
