// ComputerUseScrollToolTests.swift
// ChappieCoreTests
//
// Covers the pure parts of the fraction-based computer_scroll: argument decoding and geometry.

import Testing
import Foundation
import CoreGraphics
@testable import ChappieCore

@Suite("Fraction scroll")
struct FractionScrollTests {

    private func decode(_ json: String) -> ToolExecutionService.FractionScrollArguments? {
        try? JSONDecoder().decode(ToolExecutionService.FractionScrollArguments.self,
                                  from: Data(json.utf8))
    }

    @Test("Quoted numbers are accepted")
    func quotedNumbers() throws {
        let args = try #require(decode(#"{"x":"0.5","y":"0.25","dy":"10","monitor":"1","delay":"0.5"}"#))
        #expect(args.x.value == 0.5)
        #expect(args.y.value == 0.25)
        #expect(args.dy?.value == 10)
        #expect(args.monitor?.value == 1)
        #expect(args.delay?.value == 0.5)
    }

    @Test("dx, dy, monitor and delay are optional")
    func optionalFields() throws {
        let args = try #require(decode(#"{"x":0.5,"y":0.5}"#))
        #expect(args.dx == nil)
        #expect(args.dy == nil)
        #expect(args.monitor == nil)
        #expect(args.delay == nil)
    }

    @Test("Missing x or y fails to decode")
    func missingCoordinates() {
        #expect(decode(#"{"y":0.5,"dy":3}"#) == nil)
        #expect(decode(#"{"x":0.5,"dy":3}"#) == nil)
    }

    @Test("The centre of a display is the centre point")
    func centre() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let p = ToolExecutionService.scrollPoint(fractionX: 0.5, fractionY: 0.5, bounds: bounds)
        #expect(p == CGPoint(x: 720, y: 450))
    }

    @Test("A second display keeps its offset in CGEvent space")
    func secondDisplay() {
        let bounds = CGRect(x: 1440, y: -200, width: 1920, height: 1080)
        let p = ToolExecutionService.scrollPoint(fractionX: 0, fractionY: 1, bounds: bounds)
        #expect(p == CGPoint(x: 1440, y: 880))
    }

    @Test("Out-of-range fractions are clamped")
    func clamped() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let p = ToolExecutionService.scrollPoint(fractionX: 2, fractionY: -1, bounds: bounds)
        #expect(p == CGPoint(x: 1000, y: 0))
    }

    @Test("NaN becomes the middle instead of a crash")
    func nanInput() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let p = ToolExecutionService.scrollPoint(fractionX: .nan, fractionY: .nan, bounds: bounds)
        #expect(p == CGPoint(x: 500, y: 250))
    }
}
