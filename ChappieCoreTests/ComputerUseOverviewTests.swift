// ComputerUseOverviewTests.swift
// ChappieCoreTests
//
// Tests for the clean overview: picture is rendered correctly, cursor coordinates
// are reported as fractions of the monitor, and screenshot arguments survive quoting.

import Testing
import Foundation
import CoreGraphics
import AppKit
@testable import ChappieCore

private func flatImage(width: Int, height: Int, red: CGFloat = 0.5) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: red, green: 0.5, blue: 0.5, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

@Suite("renderPicture output")
@MainActor
struct OverviewRenderTests {

    @Test("2880×1800 native renders to 1440×900 picture")
    func retinaRender() throws {
        let m = MonitorMapping(
            displayBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
            nativeSize: CGSize(width: 2880, height: 1800))
        let bmp = try #require(ToolExecutionService.renderPicture(flatImage(width: 2880, height: 1800), mapping: m))
        #expect(bmp.pixelsWide == 1440)
        #expect(bmp.pixelsHigh == 900)
    }

    @Test("1200×800 native renders at 1:1")
    func smallRender() throws {
        let m = MonitorMapping(
            displayBounds: CGRect(x: 0, y: 0, width: 1200, height: 800),
            nativeSize: CGSize(width: 1200, height: 800))
        let bmp = try #require(ToolExecutionService.renderPicture(flatImage(width: 1200, height: 800), mapping: m))
        #expect(bmp.pixelsWide == 1200)
        #expect(bmp.pixelsHigh == 800)
    }

    @Test("Picture content is not altered during downscale")
    func contentPreserved() throws {
        let m = MonitorMapping(
            displayBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
            nativeSize: CGSize(width: 2880, height: 1800))
        let bmp = try #require(ToolExecutionService.renderPicture(flatImage(width: 2880, height: 1800, red: 0.8), mapping: m))
        // A flat red-ish fill should remain red-ish after downscale (not go black or white).
        let color = bmp.colorAt(x: 720, y: 450)?.usingColorSpace(.deviceRGB)
        let r = try #require(color?.redComponent)
        #expect(r > 0.5)
    }
}

@Suite("MonitorMapping cursor conversion")
struct CursorConversionTests {

    @Test("Cursor at the display top-left reports fraction (0,0)")
    func cursorTopLeft() {
        let m = MonitorMapping(
            displayBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
            nativeSize: CGSize(width: 2880, height: 1800))
        let f = m.toFraction(CGPoint(x: 0, y: 0))
        #expect(f.x == 0)
        #expect(f.y == 0)
    }

    @Test("Cursor at the display centre reports fraction (0.5, 0.5)")
    func cursorCentre() {
        let m = MonitorMapping(
            displayBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
            nativeSize: CGSize(width: 2880, height: 1800))
        let f = m.toFraction(CGPoint(x: 720, y: 450))
        #expect(abs(f.x - 0.5) < 1e-9)
        #expect(abs(f.y - 0.5) < 1e-9)
    }

    @Test("Cursor outside the display is clamped into 0...1")
    func cursorClamped() {
        let m = MonitorMapping(
            displayBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
            nativeSize: CGSize(width: 2880, height: 1800))
        let f = m.toFraction(CGPoint(x: 9999, y: -9999))
        #expect(f.x == 1)
        #expect(f.y == 0)
    }

    @Test("The reported fraction does not depend on the capture size")
    func cursorIgnoresCaptureSize() {
        // A Retina and a non-Retina capture of the same display must report the same fraction,
        // otherwise the coordinates the model reads would drift with the capture settings.
        let retina = MonitorMapping(
            displayBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
            nativeSize: CGSize(width: 2880, height: 1800))
        let plain = MonitorMapping(
            displayBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
            nativeSize: CGSize(width: 1440, height: 900))
        let a = retina.toFraction(CGPoint(x: 360, y: 675))
        let b = plain.toFraction(CGPoint(x: 360, y: 675))
        #expect(abs(a.x - b.x) < 1e-9)
        #expect(abs(a.y - b.y) < 1e-9)
    }

    @Test("Cursor on a second monitor (offset origin) converts correctly")
    func cursorSecondMonitor() {
        let m = MonitorMapping(
            displayBounds: CGRect(x: 1440, y: 0, width: 1280, height: 800),
            nativeSize: CGSize(width: 1280, height: 800))
        // A cursor at the top-left of the second display should report fraction (0,0).
        let f = m.toFraction(CGPoint(x: 1440, y: 0))
        #expect(f.x == 0)
        #expect(f.y == 0)
    }
}

@Suite("ComputerScreenshotArguments parsing")
struct ScreenshotArgumentsTests {

    @Test("monitor is read when the provider quotes it as a string")
    func quotedMonitor() {
        let data = Data(#"{"monitor":"1"}"#.utf8)
        let args = ComputerScreenshotArguments.parse(data)
        #expect(args.monitor?.value == 1)
    }

    @Test("screen_index is accepted as a fallback for monitor")
    func screenIndexFallback() {
        let data = Data(#"{"screen_index":2}"#.utf8)
        let args = ComputerScreenshotArguments.parse(data)
        #expect(args.screen_index?.value == 2)
    }

    @Test("Empty payload produces all-nil arguments without throwing")
    func emptyPayload() {
        let args = ComputerScreenshotArguments.parse(Data("{}".utf8))
        #expect(args.monitor == nil)
        #expect(args.screen_index == nil)
    }

    @Test("Malformed payload produces all-nil arguments without throwing")
    func malformedPayload() {
        let args = ComputerScreenshotArguments.parse(Data("not json".utf8))
        #expect(args.monitor == nil)
    }
}
