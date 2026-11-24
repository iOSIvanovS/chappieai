// ComputerUseZoomTests.swift
// ChappieCoreTests
//
// The magnifier's only real risk is geometry: a crop rectangle one step off puts the magnified
// view next to the target and the model aims with confident, exact, wrong arithmetic. These tests
// pin the rectangle, the edge behaviour and the span clamps.

import Testing
import Foundation
import CoreGraphics
@testable import ChappieCore

private func mapping(width: CGFloat = 3420, height: CGFloat = 2214) -> MonitorMapping {
    MonitorMapping(
        displayBounds: CGRect(x: 0, y: 0, width: width / 2, height: height / 2),
        nativeSize: CGSize(width: width, height: height))
}

@Suite("MonitorMapping zoom crop")
struct ZoomCropTests {

    @Test("A centred span 0.05 crop is 10% of the width, centred on the point")
    func centred() {
        let r = mapping().cropRect(span: 0.05, around: CGPoint(x: 0.5, y: 0.5))
        #expect(r.minX == 1539)
        #expect(r.minY == 996)
        #expect(r.width == 342)
        #expect(r.height == 221)
        // The centre of the crop is the point asked for, within one pixel.
        #expect(abs(r.midX - 1710) <= 1)
        #expect(abs(r.midY - 1107) <= 1)
    }

    @Test("At the top-left corner the crop keeps its size and slides inside the display")
    func topLeft() {
        let r = mapping().cropRect(span: 0.05, around: CGPoint(x: 0, y: 0))
        #expect(r.minX == 0)
        #expect(r.minY == 0)
        #expect(r.width == 342)
        #expect(r.height == 221)
    }

    @Test("At the bottom-right corner the crop stays inside the display")
    func bottomRight() {
        let m = mapping()
        let r = m.cropRect(span: 0.05, around: CGPoint(x: 1, y: 1))
        #expect(r.maxX <= m.nativeSize.width)
        #expect(r.maxY <= m.nativeSize.height)
        #expect(r.maxX >= m.nativeSize.width - 1)
        #expect(r.maxY >= m.nativeSize.height - 1)
        #expect(r.width == 342)
    }

    @Test("Crop size follows the span: smaller span means more magnification")
    func sizeFollowsSpan() {
        let m = mapping()
        let wide = m.cropRect(span: 0.10, around: CGPoint(x: 0.5, y: 0.5))
        let tight = m.cropRect(span: 0.02, around: CGPoint(x: 0.5, y: 0.5))
        #expect(wide.width == 684)
        #expect(tight.width == 137)
        #expect(tight.width < wide.width)
    }

    @Test("Span is clamped: never wider than the picture cap")
    func clampedAbove() {
        let m = mapping()
        // 1440 px long side over a 3420 px display is the largest crop the provider will not resize.
        let r = m.cropRect(span: 0.9, around: CGPoint(x: 0.5, y: 0.5))
        #expect(r.width <= 1440)
        #expect(r.height <= 1440)
    }

    @Test("Span is clamped: never thinner than the minimum")
    func clampedBelow() {
        let r = mapping().cropRect(span: 0.0001, around: CGPoint(x: 0.5, y: 0.5))
        #expect(r.width == 34)
    }

    @Test("NaN span falls back to a readable default instead of an empty crop")
    func nanSpan() {
        let r = mapping().cropRect(span: CGFloat.nan, around: CGPoint(x: 0.5, y: 0.5))
        #expect(r.width == 342)
        #expect(r.height == 221)
    }

    @Test("NaN centre falls back to the middle of the display")
    func nanCentre() {
        let r = mapping().cropRect(span: 0.05, around: CGPoint(x: CGFloat.nan, y: CGFloat.nan))
        #expect(abs(r.midX - 1710) <= 1)
        #expect(abs(r.midY - 1107) <= 1)
    }

    @Test("A display smaller than the cap allows the full 0.25 span without shrinking")
    func smallDisplaySpan() {
        let m = mapping(width: 1200, height: 800)
        #expect(m.maxUsableZoomSpan == 0.25)
        let r = m.cropRect(span: 0.25, around: CGPoint(x: 0.5, y: 0.5))
        #expect(r.width == 600)
    }

    @Test("The crop rectangle maps back to monitor fractions that bracket the point")
    func fractionsBracketPoint() {
        let m = mapping()
        let r = m.cropRect(span: 0.05, around: CGPoint(x: 0.3, y: 0.4))
        let left = r.minX / m.nativeSize.width
        let right = r.maxX / m.nativeSize.width
        let top = r.minY / m.nativeSize.height
        let bottom = r.maxY / m.nativeSize.height
        #expect(left < 0.3 && 0.3 < right)
        #expect(top < 0.4 && 0.4 < bottom)
        // Half the span on each side, so the point sits in the middle of the bracket.
        #expect(abs((left + right) / 2 - 0.3) < 0.001)
        #expect(abs((top + bottom) / 2 - 0.4) < 0.001)
    }
}
