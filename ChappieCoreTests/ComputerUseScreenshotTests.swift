// ComputerUseScreenshotTests.swift
// ChappieCoreTests
//
// Screenshot geometry for Computer Use: the overview is capped at 1440 px, a zoom comes back at
// native resolution, both share one coordinate space, and the grid really paints pixels.

import Testing
import Foundation
import CoreGraphics
import AppKit
@testable import ChappieCore

// MARK: - Helpers

private enum SyntheticScreen {

    /// A flat fill keeps pixel comparisons free of scaling noise.
    static func image(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// A 2880×1800 Retina display halves into the 1440 px overview.
    static func retina() -> CGImage { image(width: 2880, height: 1800) }
}

private func differingBytes(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Int {
    guard let a = lhs.bitmapData, let b = rhs.bitmapData,
          lhs.bytesPerRow == rhs.bytesPerRow, lhs.pixelsHigh == rhs.pixelsHigh else { return -1 }
    let count = lhs.bytesPerRow * lhs.pixelsHigh
    var different = 0
    for index in 0..<count where a[index] != b[index] { different += 1 }
    return different
}

// MARK: - Geometry

@Suite("Screenshot geometry")
struct ScreenshotGeometryTests {

    @Test("A Retina screen is halved into a 1440 px overview")
    func retinaOverview() {
        let geo = ScreenshotGeometry(nativeSize: CGSize(width: 2880, height: 1800))
        #expect(geo.imageSize.width == 1440)
        #expect(geo.imageSize.height == 900)
    }

    @Test("A screen narrower than the cap is never upscaled")
    func smallScreenIsOneToOne() {
        let geo = ScreenshotGeometry(nativeSize: CGSize(width: 1200, height: 800))
        #expect(geo.scale == 1)
        #expect(geo.imageSize.width == 1200)
        #expect(geo.imageSize.height == 800)
    }

    @Test("Major grid lines land about 90 output pixels apart")
    func gridSteps() {
        #expect(ToolExecutionService.majorGridStep(pxPerImage: 1) == 100)
        #expect(ToolExecutionService.majorGridStep(pxPerImage: 2.4) == 50)
        #expect(ToolExecutionService.majorGridStep(pxPerImage: 10) == 10)
    }

    @Test("A zoom region is clamped to the screen")
    func regionClampedToBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let region = ToolExecutionService.clampRegion(
            CGRect(x: 1200, y: 800, width: 400, height: 300), to: bounds)
        #expect(region.maxX <= 1440)
        #expect(region.maxY <= 900)
        #expect(region.width == 400)
        #expect(region.height == 300)
    }

    @Test("A degenerate zoom region is grown to a usable size")
    func tinyRegionGrows() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let region = ToolExecutionService.clampRegion(
            CGRect(x: 100, y: 100, width: 3, height: 2), to: bounds)
        #expect(region.width == 24)
        #expect(region.height == 24)
    }
}

// MARK: - Rendering

@Suite("Screenshot rendering")
@MainActor
struct ScreenshotRenderingTests {

    @Test("The overview is 1440×900 for a 2880×1800 display")
    func overviewSize() throws {
        let bitmap = try #require(ToolExecutionService.renderScreenshot(
            SyntheticScreen.retina(), region: nil, grid: false))
        #expect(bitmap.pixelsWide == 1440)
        #expect(bitmap.pixelsHigh == 900)
    }

    @Test("A zoom comes back at native resolution, not downscaled")
    func zoomIsNative() throws {
        // At scale 0.5 a 400×300 region of overview pixels covers 800×600 device pixels.
        let bitmap = try #require(ToolExecutionService.renderScreenshot(
            SyntheticScreen.retina(),
            region: CGRect(x: 200, y: 100, width: 400, height: 300),
            grid: true))
        #expect(bitmap.pixelsWide == 800)
        #expect(bitmap.pixelsHigh == 600)
    }

    @Test("A zoom bigger than the cap is reduced instead of sent at full size")
    func zoomCapped() throws {
        let bitmap = try #require(ToolExecutionService.renderScreenshot(
            SyntheticScreen.retina(),
            region: CGRect(x: 0, y: 0, width: 1440, height: 900),
            grid: true))
        #expect(bitmap.pixelsWide == Int(ScreenshotGeometry.overviewMaxSide))
        #expect(bitmap.pixelsHigh == 900)
    }

    @Test("grid: true actually paints over the captured pixels")
    func gridPaints() throws {
        let plain = try #require(ToolExecutionService.renderScreenshot(
            SyntheticScreen.retina(), region: nil, grid: false))
        let gridded = try #require(ToolExecutionService.renderScreenshot(
            SyntheticScreen.retina(), region: nil, grid: true))
        #expect(differingBytes(plain, gridded) > 1000, "lines and labels must change pixels")
    }

    @Test("A zoom carries its caption strip at the bottom")
    func zoomCaptionPaints() throws {
        let plain = try #require(ToolExecutionService.renderScreenshot(
            SyntheticScreen.retina(),
            region: CGRect(x: 200, y: 100, width: 400, height: 300),
            grid: false))
        let captioned = try #require(ToolExecutionService.renderScreenshot(
            SyntheticScreen.retina(),
            region: CGRect(x: 200, y: 100, width: 400, height: 300),
            grid: true))
        #expect(differingBytes(plain, captioned) > 100)
    }
}
