// ComputerUseAimTests.swift
// ChappieCoreTests

import Testing
import CoreGraphics
@testable import ChappieCore

@Suite("computer_aim geometry and state")
struct ComputerUseAimTests {

    // A Retina main display: 1728x1117 points captured as 3456x2234 pixels.
    private let bounds = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let native = CGSize(width: 3456, height: 2234)

    @Test func centreFractionHitsCentreOfDisplay() {
        let g = AimGeometry(fraction: CGPoint(x: 0.5, y: 0.5), monitor: 0,
                            displayBounds: bounds, nativeSize: native)
        #expect(g.eventPoint == CGPoint(x: 864, y: 558.5))
        #expect(g.pixelPoint == CGPoint(x: 1728, y: 1117))
    }

    @Test func secondMonitorOriginIsAdded() {
        let right = CGRect(x: 1728, y: -200, width: 1920, height: 1080)
        let g = AimGeometry(fraction: CGPoint(x: 0, y: 1), monitor: 1,
                            displayBounds: right, nativeSize: CGSize(width: 1920, height: 1080))
        #expect(g.eventPoint == CGPoint(x: 1728, y: 880))
    }

    @Test func cropIsTwoHundredPointsInPixels() {
        let g = AimGeometry(fraction: CGPoint(x: 0.5, y: 0.5), monitor: 0,
                            displayBounds: bounds, nativeSize: native)
        #expect(g.cropPixels.width == 400)
        #expect(g.cropPixels.height == 400)
        #expect(g.crosshairInCrop == CGPoint(x: 200, y: 200))
    }

    @Test func cropNearCornerKeepsSizeAndStaysInside() {
        let g = AimGeometry(fraction: CGPoint(x: 0.01, y: 0.01), monitor: 0,
                            displayBounds: bounds, nativeSize: native)
        #expect(g.cropPixels.minX == 0)
        #expect(g.cropPixels.minY == 0)
        #expect(g.cropPixels.width == 400)
        // The crosshair is off-centre in the crop but still points at the aim pixel.
        #expect(g.crosshairInCrop.x == g.pixelPoint.x)
        #expect(g.crosshairInCrop.y == g.pixelPoint.y)
    }

    @Test func cropNearFarEdgeStaysInside() {
        let g = AimGeometry(fraction: CGPoint(x: 1, y: 1), monitor: 0,
                            displayBounds: bounds, nativeSize: native)
        #expect(g.cropPixels.maxX == native.width)
        #expect(g.cropPixels.maxY == native.height)
    }

    @Test func outOfRangeAndNaNFractionsAreClamped() {
        let g = AimGeometry(fraction: CGPoint(x: 7, y: -3), monitor: 0,
                            displayBounds: bounds, nativeSize: native)
        #expect(g.fraction == CGPoint(x: 1, y: 0))
        let n = AimGeometry(fraction: CGPoint(x: CGFloat.nan, y: 0.5), monitor: 0,
                            displayBounds: bounds, nativeSize: native)
        #expect(n.fraction.x == 0.5)
    }

    @Test func nonRetinaDisplayUsesOnePixelPerPoint() {
        let b = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let g = AimGeometry(fraction: CGPoint(x: 0.5, y: 0.5), monitor: 0,
                            displayBounds: b, nativeSize: CGSize(width: 1920, height: 1080))
        #expect(g.cropPixels.width == 200)
    }

    @Test func takeReturnsAimOnceThenNil() {
        let store = AimStore()
        let aim = AimPoint(monitor: 0, eventPoint: CGPoint(x: 1, y: 2), fraction: CGPoint(x: 0.1, y: 0.2))
        store.set(aim)
        #expect(store.peek() == aim)
        #expect(store.take() == aim)
        #expect(store.take() == nil)
        #expect(store.peek() == nil)
    }

    @Test func newAimReplacesOldOne() {
        let store = AimStore()
        store.set(AimPoint(monitor: 0, eventPoint: .zero, fraction: .zero))
        let second = AimPoint(monitor: 1, eventPoint: CGPoint(x: 5, y: 5), fraction: CGPoint(x: 1, y: 1))
        store.set(second)
        #expect(store.take() == second)
    }

    @Test func clearDropsPendingAim() {
        let store = AimStore()
        store.set(AimPoint(monitor: 0, eventPoint: .zero, fraction: .zero))
        store.clear()
        #expect(store.take() == nil)
    }
}
