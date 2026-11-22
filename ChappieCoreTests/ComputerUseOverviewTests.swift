// ComputerUseOverviewTests.swift
// ChappieCoreTests
//
// The clean overview of computer_screenshot: the picture stays untouched unless the coarse grid is
// requested, grid lines sit exactly on fractions of 0.1, and the monitor argument survives quoting.

import Testing
import Foundation
import CoreGraphics
import AppKit
@testable import ChappieCore

private func flatRetinaScreen() -> CGImage {
    let ctx = CGContext(data: nil, width: 2880, height: 1800,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 2880, height: 1800))
    return ctx.makeImage()!
}

private func red(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
    rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.redComponent ?? -1
}

@Suite("Clean overview")
@MainActor
struct ComputerUseOverviewTests {

    @Test("A clean render is the flat capture, with nothing drawn on it")
    func cleanIsUntouched() throws {
        let rep = try #require(ToolExecutionService.renderScreenshot(
            flatRetinaScreen(), region: nil, grid: false))
        // A flat fill stays flat: pixels where grid lines would fall equal pixels far from them.
        let reference = red(rep, 72, 405)
        #expect(reference >= 0)
        #expect(abs(red(rep, 144, 405) - reference) < 0.01)
        #expect(abs(red(rep, 700, 450) - reference) < 0.01)
        #expect(abs(red(rep, 720, 300) - reference) < 0.01)
    }

    @Test("Grid lines sit on the 0.1 fractions and leave the cells between them untouched")
    func gridOnFractions() throws {
        let plain = try #require(ToolExecutionService.renderScreenshot(
            flatRetinaScreen(), region: nil, grid: false))
        let gridded = try #require(ToolExecutionService.renderScreenshot(
            flatRetinaScreen(), region: nil, grid: false))
        ToolExecutionService.drawFractionGrid(on: gridded)

        // 0.1 of 1440 px is column 144; column 72 and row 405 are mid-cell and carry no line.
        #expect(red(gridded, 144, 405) - red(plain, 144, 405) > 0.1)
        #expect(abs(red(gridded, 72, 405) - red(plain, 72, 405)) < 0.02)
        // 0.5 of 900 px is row 450.
        #expect(red(gridded, 700, 450) - red(plain, 700, 450) > 0.1)
    }

    @Test("The grid does not change the size of the picture")
    func gridKeepsSize() throws {
        let rep = try #require(ToolExecutionService.renderScreenshot(
            flatRetinaScreen(), region: nil, grid: false))
        ToolExecutionService.drawFractionGrid(on: rep)
        #expect(rep.pixelsWide == 1440)
        #expect(rep.pixelsHigh == 900)
    }

    @Test("monitor and grid are read even when the provider quotes them")
    func quotedArguments() {
        let data = Data(#"{"monitor":"1","grid":"true"}"#.utf8)
        let args = ComputerScreenshotArguments.parse(data)
        #expect(args.monitor?.value == 1)
        #expect(args.grid?.value == true)
    }

    @Test("Without arguments the grid is off and the main monitor is used")
    func defaults() {
        let args = ComputerScreenshotArguments.parse(Data("{}".utf8))
        #expect(args.monitor == nil)
        #expect(args.grid == nil)
        #expect(args.region == nil)
        #expect(args.wantsMarks == false)
    }
}
