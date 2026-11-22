// ComputerUseScrollTool.swift
// ChappieCore
//
// WHY THIS FILE:
// computer_scroll in fractions of the monitor image, with an explicit monitor. Scrolling needs no
// pixel precision and is repeated often, so it does not go through the aim: the model names the
// spot (0...1 of the image) and the monitor, and gets a clean overview back.

import Foundation
import CoreGraphics
import AppKit

extension ToolExecutionService {

    /// Arguments of computer_scroll. x and y are fractions 0...1 of the monitor image.
    struct FractionScrollArguments: Decodable {
        var x: FlexDouble
        var y: FlexDouble
        var dx: FlexDouble?
        var dy: FlexDouble?
        var monitor: FlexInt?
        var delay: FlexDouble?
    }

    // MARK: - Execution

    func performFractionScroll(argsData: Data) async -> String {
        guard let args = try? JSONDecoder().decode(FractionScrollArguments.self, from: argsData) else {
            return "❌ computer_scroll: 'x' and 'y' are required, as fractions from 0 to 1 of the monitor image."
        }
        let dx = args.dx?.value ?? 0
        let dy = args.dy?.value ?? 0
        guard dx != 0 || dy != 0 else {
            return "❌ computer_scroll: Pass a non-zero 'dy' (vertical) or 'dx' (horizontal) amount in ticks."
        }
        let monitor = args.monitor?.value ?? 0
        let delay = args.delay?.value ?? 1.0

        let failure: String? = await MainActor.run {
            guard let screen = Self.screen(at: monitor) else {
                return "❌ computer_scroll: Monitor \(monitor) not found. Connected monitors: \(NSScreen.screens.count)."
            }
            let point = Self.scrollPoint(fractionX: args.x.value, fractionY: args.y.value,
                                         bounds: CGDisplayBounds(Self.displayID(of: screen)))
            // Positive dy scrolls down, the opposite of the CGScrollWheelEvent sign.
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                                      wheel1: Int32(-dy), wheel2: Int32(dx), wheel3: 0) else {
                return "❌ computer_scroll: Failed to create the scroll event."
            }
            // The wheel goes to the window under the cursor, so move it there first.
            CGWarpMouseCursorPosition(point)
            CGAssociateMouseAndMouseCursorPosition(1)
            event.location = point
            event.post(tap: .cghidEventTap)
            return nil
        }
        if let failure { return failure }
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        return await MainActor.run {
            Self.overviewScreenshot(monitor: monitor, grid: false)
        }
    }

    // MARK: - Geometry

    /// Fractions of the monitor image to a CGEvent point. Out-of-range and NaN input is clamped,
    /// the same way computer_aim treats it.
    static func scrollPoint(fractionX: Double, fractionY: Double, bounds: CGRect) -> CGPoint {
        func unit(_ v: Double) -> CGFloat { v.isNaN ? 0.5 : CGFloat(min(max(v, 0), 1)) }
        return CGPoint(x: bounds.minX + unit(fractionX) * bounds.width,
                       y: bounds.minY + unit(fractionY) * bounds.height)
    }
}
