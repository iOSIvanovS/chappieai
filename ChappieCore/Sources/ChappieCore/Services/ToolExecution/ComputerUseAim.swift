// ComputerUseAim.swift
// ChappieCore
//
// WHY THIS FILE:
// computer_aim picks the point a later click will hit. The model never passes pixel coordinates to
// the click: it aims in fractions of the monitor image, looks at a native-resolution crop with a
// crosshair, and only then clicks the remembered point. This file holds the pure geometry and the
// one-shot state; drawing and tool wiring live elsewhere.

import Foundation
import CoreGraphics

/// The point the next click will hit, remembered between computer_aim and computer_click.
struct AimPoint: Equatable {
    let monitor: Int
    /// Click position in CGEvent space (top-left origin of the main display).
    let eventPoint: CGPoint
    /// What the model asked for, 0...1 of the monitor image.
    let fraction: CGPoint
}

/// Everything computer_aim derives from fractions: the click point and the crop to show.
struct AimGeometry: Equatable {
    /// The crop shows this many points on each side of the aim point.
    static let halfSidePoints: CGFloat = 100

    let monitor: Int
    /// Fractions after clamping to 0...1.
    let fraction: CGPoint
    let eventPoint: CGPoint
    /// Aim point in native capture pixels.
    let pixelPoint: CGPoint
    /// Square crop in native capture pixels, always inside the capture.
    let cropPixels: CGRect

    /// Aim point inside the crop, in native pixels: where the crosshair is drawn.
    var crosshairInCrop: CGPoint {
        CGPoint(x: pixelPoint.x - cropPixels.minX, y: pixelPoint.y - cropPixels.minY)
    }

    var aimPoint: AimPoint {
        AimPoint(monitor: monitor, eventPoint: eventPoint, fraction: fraction)
    }

    /// - Parameters:
    ///   - displayBounds: the display in CGEvent space (CGDisplayBounds), points.
    ///   - nativeSize: the captured image of that display, device pixels.
    init(fraction: CGPoint, monitor: Int, displayBounds: CGRect, nativeSize: CGSize) {
        let fx = AimGeometry.unit(fraction.x)
        let fy = AimGeometry.unit(fraction.y)
        self.monitor = monitor
        self.fraction = CGPoint(x: fx, y: fy)
        eventPoint = CGPoint(x: displayBounds.minX + fx * displayBounds.width,
                             y: displayBounds.minY + fy * displayBounds.height)
        pixelPoint = CGPoint(x: fx * nativeSize.width, y: fy * nativeSize.height)

        // Points to device pixels, taken from the capture itself so Retina needs no special case.
        let pixelsPerPoint = nativeSize.width / max(displayBounds.width, 1)
        let side = min(2 * AimGeometry.halfSidePoints * pixelsPerPoint,
                       nativeSize.width, nativeSize.height).rounded()
        // Shift rather than shrink near an edge, so the crop keeps its size and the scale stays honest.
        let x0 = min(max((pixelPoint.x - side / 2).rounded(), 0), nativeSize.width - side)
        let y0 = min(max((pixelPoint.y - side / 2).rounded(), 0), nativeSize.height - side)
        cropPixels = CGRect(x: x0, y: y0, width: side, height: side)
    }

    /// NaN and out-of-range input become a usable fraction instead of a crash.
    private static func unit(_ v: CGFloat) -> CGFloat {
        v.isNaN ? 0.5 : min(max(v, 0), 1)
    }
}

/// The single pending aim. A click consumes it, so a second click without a new aim is refused.
final class AimStore: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: AimPoint?

    func set(_ aim: AimPoint) {
        lock.lock(); defer { lock.unlock() }
        pending = aim
    }

    func peek() -> AimPoint? {
        lock.lock(); defer { lock.unlock() }
        return pending
    }

    /// Returns the pending aim and forgets it in one step, so no caller can reuse it.
    func take() -> AimPoint? {
        lock.lock(); defer { lock.unlock() }
        let aim = pending
        pending = nil
        return aim
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        pending = nil
    }
}
