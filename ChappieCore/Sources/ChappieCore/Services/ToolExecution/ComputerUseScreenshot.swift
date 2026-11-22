// ComputerUseScreenshot.swift
// ChappieCore
//
// WHY THIS FILE:
// Pixel work for the computer_screenshot tool: the downscaled overview image, the zoomed
// region, and the coordinate grid drawn over both. Split out of ComputerUseExecution.swift
// so pixel rendering and event synthesis stay separately readable.
//
// COORDINATE SPACE:
// Every number the model reads off a screenshot — grid labels, zoom caption — is in
// "overview image pixels": the space of the plain downscaled full-screen image. Zooming
// magnifies part of that space but never renumbers it, so computer_click needs no special
// case for a zoomed image.

import Foundation
import CoreGraphics
import AppKit

/// Geometry of a screenshot: native device pixels → the overview image the model sees.
struct ScreenshotGeometry {
    /// Long side of the overview image. Providers downscale anything larger anyway, and a
    /// smaller image keeps the per-step token cost predictable.
    static let overviewMaxSide: CGFloat = 1440

    let nativeSize: CGSize
    /// Native pixels → overview image pixels.
    let scale: CGFloat

    init(nativeSize: CGSize) {
        self.nativeSize = nativeSize
        scale = min(1.0, ScreenshotGeometry.overviewMaxSide /
                             max(nativeSize.width, nativeSize.height, 1))
    }

    var imageSize: CGSize {
        CGSize(width:  (nativeSize.width  * scale).rounded(),
               height: (nativeSize.height * scale).rounded())
    }
}

extension ToolExecutionService {

    // MARK: - Entry point

    /// Renders a screenshot and returns it behind viewImageMarker as a data URI.
    /// - Parameters:
    ///   - region: rect in overview-image pixels to magnify. nil → whole screen, downscaled.
    ///   - grid: draw labelled coordinate lines (labels are overview-image pixels).
    @MainActor
    static func screenshotDataURI(screenIndex: Int,
                                  grid: Bool = false,
                                  region: CGRect? = nil) -> String {
        guard let screen = Self.screen(at: screenIndex) else {
            return "❌ computer_screenshot: Screen index \(screenIndex) not found. Available: \(NSScreen.screens.count)."
        }
        guard let full = Self.captureDisplay(screen) else {
            return "❌ computer_screenshot: Failed to capture screen \(screenIndex)."
        }
        guard let bitmap = Self.renderScreenshot(full, region: region, grid: grid),
              let jpeg = bitmap.representation(using: .jpeg,
                                               properties: [.compressionFactor: 0.7]) else {
            return "❌ computer_screenshot: Failed to encode screenshot."
        }
        return "\(ToolExecutionService.viewImageMarker)data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }

    // MARK: - Numbered screenshot

    /// A screenshot with the other application's controls boxed and numbered, returned together
    /// with the list the model reads. The numbers are remembered so computer_click can use them.
    /// - Parameter action: what was just done, reported above the list (nil for a plain capture).
    @MainActor
    static func markedScreenshot(screenIndex: Int,
                                 grid: Bool,
                                 region: CGRect?,
                                 action: String? = nil) -> String {
        guard let screen = Self.screen(at: screenIndex) else {
            return "❌ computer_screenshot: Screen index \(screenIndex) not found. Available: \(NSScreen.screens.count)."
        }
        guard let full = Self.captureDisplay(screen) else {
            return "❌ computer_screenshot: Failed to capture screen \(screenIndex)."
        }
        let nativeSize = CGSize(width: full.width, height: full.height)
        let (appName, targetPid, elements, note) = Self.markTarget(for: screen)

        let marks = ElementMarks.layout(
            elements,
            transform: Self.displayTransform(for: screen, nativeSize: nativeSize),
            overviewSize: ScreenshotGeometry(nativeSize: nativeSize).imageSize
        )
        guard let bitmap = Self.renderScreenshot(full, region: region, grid: grid, marks: marks),
              let jpeg = bitmap.representation(using: .jpeg,
                                               properties: [.compressionFactor: 0.7]) else {
            return "❌ computer_screenshot: Failed to encode screenshot."
        }

        let shot = Self.markedScreenshots.record(applicationName: appName, pid: targetPid, marks: marks)
        let shown = ElementMarks.visible(marks, in: Self.cropPlan(nativeSize: nativeSize,
                                                                 region: region).covered)
        let text = Self.elementListText(action: action, shot: shot, shown: shown,
                                        isCrop: region != nil, note: note)
        return ToolImageResult(
            text: text,
            images: [.init(label: "Screenshot #\(shot.id) — the numbered boxes match the list above.",
                           dataURI: "data:image/jpeg;base64,\(jpeg.base64EncodedString())")]
        ).encoded()
    }

    /// Name, process, controls and any caveat for the window the user is working in.
    /// The caveat is text, not silence: an empty picture with no explanation reads like a bug.
    @MainActor
    static func markTarget(for screen: NSScreen)
        -> (name: String, pid: pid_t?, elements: [AccessibleElement], note: String) {
        guard AXIsProcessTrusted() else {
            return ("this screen", nil, [],
                    "Accessibility permission is not granted, so no controls could be read. Grant it in "
                    + "System Settings → Privacy & Security → Accessibility to click by number.")
        }
        guard let target = AccessibilityReader.targetWindow(
                excluding: ProcessInfo.processInfo.processIdentifier,
                within: CGDisplayBounds(Self.displayID(of: screen))) else {
            return ("this screen", nil, [],
                    "No window of another application was found on this screen, so there was nothing to number.")
        }
        let name = NSRunningApplication(processIdentifier: target.pid)?.localizedName ?? "another application"
        return (name, target.pid,
                AccessibilityReader.elements(of: target.pid, matching: target.bounds), "")
    }

    /// The text half of a numbered screenshot. Every claim here is a rule the click side relies on:
    /// which picture the numbers belong to, and that they do not survive the next action.
    static func elementListText(action: String?,
                                shot: MarkedScreenshot,
                                shown: [ElementMark],
                                isCrop: Bool,
                                note: String) -> String {
        var lines: [String] = []
        if let action, !action.isEmpty { lines.append(action) }
        if !note.isEmpty { lines.append(note) }

        guard !shot.marks.isEmpty else {
            lines.append("Screenshot #\(shot.id) of \(shot.applicationName): no interactive controls were reported"
                         + " for this window. Some applications draw their own interface and expose nothing.")
            lines.append("Without numbers, use the grid: read a position off the labelled lines and pass it to"
                         + " computer_click(x:, y:).")
            return lines.joined(separator: "\n")
        }

        let total = shot.marks.count
        lines.append(isCrop
            ? "Screenshot #\(shot.id) of \(shot.applicationName): \(shown.count) of \(total) numbered controls are inside this crop."
            : "Screenshot #\(shot.id) of \(shot.applicationName): \(total) interactive controls are numbered on the picture.")
        lines.append("Click one by number — computer_click(element: 7) — the centre comes from macOS, not from"
                     + " your reading of the picture. These numbers describe screenshot #\(shot.id) only."
                     + " Every computer action returns a fresh numbered picture, so read the numbers from the latest one.")
        lines.append(contentsOf: shown.map(\.listLine))
        return lines.joined(separator: "\n")
    }

    // MARK: - Element lookup

    enum ElementLookup {
        /// Click point in CGEvent space, what it is, and the app that owns it.
        case point(CGPoint, description: String, pid: pid_t?)
        case failure(String)
    }

    /// Turns a number from a screenshot list into the exact click point, and says what it is.
    /// AX frames and CGEvent points share one origin, so the centre needs no conversion.
    nonisolated static func resolveElement(_ number: Int,
                                           in store: MarkedScreenshotStore = markedScreenshots) -> ElementLookup {
        guard let shot = store.latest() else {
            return .failure("no numbered screenshot is in effect. Call computer_screenshot with marks:true,"
                            + " then pass a number from the list it returns.")
        }
        guard let mark = shot.element(number: number) else {
            let available = shot.marks.isEmpty
                ? "none"
                : shot.marks.map { "\($0.number)" }.joined(separator: ", ")
            return .failure("screenshot #\(shot.id) of \(shot.applicationName) has no element \(number)."
                            + " Available numbers: \(available).")
        }
        let name = mark.element.title.isEmpty ? "(untitled)" : mark.element.title
        return .point(mark.element.center,
                      description: "[\(number)] \(mark.element.role) \"\(name)\" in \(shot.applicationName)",
                      pid: shot.pid)
    }

    @MainActor
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            ?? CGMainDisplayID()
    }

    /// CGDisplayCreateImage is the non-deprecated replacement for CGWindowListCreateImage
    /// when capturing a whole display; it maps onto the NSScreen through its displayID.
    @MainActor
    static func captureDisplay(_ screen: NSScreen) -> CGImage? {
        CGDisplayCreateImage(Self.displayID(of: screen))
    }

    /// The full AX-points → overview-image-pixels chain for one display. CGDisplayBounds is used
    /// for the origin because it already lives in the top-left global space AX frames are in.
    @MainActor
    static func displayTransform(for screen: NSScreen, nativeSize: CGSize) -> DisplayTransform {
        let geo = ScreenshotGeometry(nativeSize: nativeSize)
        return DisplayTransform(displayBounds: CGDisplayBounds(Self.displayID(of: screen)),
                                backingScale: screen.backingScaleFactor,
                                imageScale: geo.scale)
    }

    // MARK: - Rendering

    @MainActor
    static func renderScreenshot(_ full: CGImage,
                                 region: CGRect?,
                                 grid: Bool,
                                 marks: [ElementMark] = []) -> NSBitmapImageRep? {
        let geo      = ScreenshotGeometry(nativeSize: CGSize(width: full.width, height: full.height))
        let requested = region.map { Self.clampRegion($0, to: CGRect(origin: .zero, size: geo.imageSize)) }

        let plan = Self.cropPlan(nativeSize: geo.nativeSize, region: region)
        guard let crop = full.cropping(to: plan.pixels) else { return nil }
        // The area actually covered, back in overview-image pixels — grid labels and element
        // numbers are both expressed in that space.
        let covered = plan.covered
        let cropW = plan.pixels.width
        let cropH = plan.pixels.height

        // The overview keeps the familiar downscaled size. A zoom is delivered at native
        // resolution (capped): telling one small button from its neighbour is its whole point.
        var outSize = geo.imageSize
        if requested != nil {
            let s = min(1.0, ScreenshotGeometry.overviewMaxSide / max(cropW, cropH))
            outSize = CGSize(width: (cropW * s).rounded(), height: (cropH * s).rounded())
        }
        let outW = max(1, outSize.width)
        let outH = max(1, outSize.height)

        // An explicit bitmap rep keeps the output at exactly outW×outH pixels. Letting NSImage
        // pick its own backing scale would quietly double the size on a Retina display and every
        // coordinate read off the image would then be off by a factor of two.
        guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(outW), pixelsHigh: Int(outH),
                bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        bitmap.size = NSSize(width: outW, height: outH)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let cg = graphics.cgContext
        cg.interpolationQuality = .high
        cg.draw(crop, in: CGRect(x: 0, y: 0, width: outW, height: outH))

        if grid {
            Self.drawGrid(on: cg, outSize: CGSize(width: outW, height: outH), covered: covered)
        }
        // Marks come last so a box is never hidden under a grid line or the zoom caption.
        ElementMarks.draw(marks, on: cg, outSize: CGSize(width: outW, height: outH), covered: covered)
        if requested != nil {
            Self.drawZoomCaption(on: cg, outSize: CGSize(width: outW, height: outH))
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    // MARK: - Grid

    /// Distance between labelled lines, in overview-image pixels, aiming at ~90 output pixels
    /// between them: dense enough to interpolate a position, sparse enough to read the picture.
    static func majorGridStep(pxPerImage: CGFloat) -> CGFloat {
        let steps: [CGFloat] = [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000]
        return steps.first { $0 * pxPerImage >= 90 } ?? 1000
    }

    /// What a screenshot of `region` actually covers: the native pixels cut out of the capture, and
    /// the same area in overview-image pixels. One source of truth for the renderer and for the
    /// element list, so the boxes and the numbers in the text always describe the same area.
    struct ScreenshotCrop: Equatable {
        /// Crop rectangle in native device pixels.
        let pixels: CGRect
        /// The area it covers, in overview-image pixels.
        let covered: CGRect
    }

    static func cropPlan(nativeSize: CGSize, region: CGRect?) -> ScreenshotCrop {
        let geo      = ScreenshotGeometry(nativeSize: nativeSize)
        let overview = CGRect(origin: .zero, size: geo.imageSize)
        let wanted   = region.map { clampRegion($0, to: overview) } ?? overview

        // Snap to whole device pixels so the crop and its labels describe the same area.
        let x0 = (wanted.minX / geo.scale).rounded(.down)
        let y0 = (wanted.minY / geo.scale).rounded(.down)
        let x1 = min(nativeSize.width,  (wanted.maxX / geo.scale).rounded(.up))
        let y1 = min(nativeSize.height, (wanted.maxY / geo.scale).rounded(.up))
        let w  = max(1, x1 - x0)
        let h  = max(1, y1 - y0)
        return ScreenshotCrop(pixels: CGRect(x: x0, y: y0, width: w, height: h),
                              covered: CGRect(x: x0 * geo.scale, y: y0 * geo.scale,
                                              width: w * geo.scale, height: h * geo.scale))
    }

    /// Clamps a zoom request to the screen and to a usable minimum size.
    static func clampRegion(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let minSide: CGFloat = 24
        let w = min(max(abs(rect.width),  minSide), bounds.width)
        let h = min(max(abs(rect.height), minSide), bounds.height)
        let x = min(max(rect.minX, bounds.minX), bounds.maxX - w)
        let y = min(max(rect.minY, bounds.minY), bounds.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    @MainActor
    static func drawGrid(on cg: CGContext, outSize: CGSize, covered: CGRect) {
        let pxX = outSize.width  / max(covered.width,  1)
        let pxY = outSize.height / max(covered.height, 1)
        let major = majorGridStep(pxPerImage: min(pxX, pxY))
        let minor = major / 5
        let drawMinor = minor * min(pxX, pxY) >= 9

        // Drawn in an unflipped context (origin bottom-left); y is converted per line so text
        // stays upright without juggling a flipped CTM.
        func outX(_ imageX: CGFloat) -> CGFloat { (imageX - covered.minX) * pxX }
        func outY(_ imageY: CGFloat) -> CGFloat { outSize.height - (imageY - covered.minY) * pxY }

        // Magenta reads on both light and dark interfaces; the alpha keeps it from hiding content.
        func strokeVertical(step: CGFloat, alpha: CGFloat, width: CGFloat) {
            cg.setStrokeColor(NSColor(srgbRed: 1, green: 0.16, blue: 0.55, alpha: alpha).cgColor)
            cg.setLineWidth(width)
            var imageX = (covered.minX / step).rounded(.up) * step
            while imageX <= covered.maxX {
                let x = outX(imageX).rounded() + 0.5
                cg.move(to:    CGPoint(x: x, y: 0))
                cg.addLine(to: CGPoint(x: x, y: outSize.height))
                imageX += step
            }
            cg.strokePath()
        }
        func strokeHorizontal(step: CGFloat, alpha: CGFloat, width: CGFloat) {
            cg.setStrokeColor(NSColor(srgbRed: 1, green: 0.16, blue: 0.55, alpha: alpha).cgColor)
            cg.setLineWidth(width)
            var imageY = (covered.minY / step).rounded(.up) * step
            while imageY <= covered.maxY {
                let y = outY(imageY).rounded() + 0.5
                cg.move(to:    CGPoint(x: 0, y: y))
                cg.addLine(to: CGPoint(x: outSize.width, y: y))
                imageY += step
            }
            cg.strokePath()
        }

        if drawMinor {
            strokeVertical(step: minor,   alpha: 0.16, width: 1)
            strokeHorizontal(step: minor, alpha: 0.16, width: 1)
        }
        strokeVertical(step: major,   alpha: 0.45, width: 1)
        strokeHorizontal(step: major, alpha: 0.45, width: 1)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let fontSize = max(11, min(20, outSize.width / 130))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.white
        ]

        func label(_ text: String, at point: CGPoint) {
            let size = (text as NSString).size(withAttributes: attrs)
            // Keep every label inside the image: a clipped number is worse than a moved one.
            let p = CGPoint(x: min(max(point.x, 2), outSize.width  - size.width  - 2),
                            y: min(max(point.y, 2), outSize.height - size.height - 2))
            cg.setFillColor(NSColor(white: 0, alpha: 0.55).cgColor)
            cg.fill(CGRect(x: p.x - 2, y: p.y - 1,
                           width: size.width + 4, height: size.height + 2))
            (text as NSString).draw(at: p, withAttributes: attrs)
        }

        var imageX = (covered.minX / major).rounded(.up) * major
        while imageX <= covered.maxX {
            label("\(Int(imageX.rounded()))", at: CGPoint(x: outX(imageX) + 3,
                                                          y: outSize.height - fontSize - 6))
            imageX += major
        }
        var imageY = (covered.minY / major).rounded(.up) * major
        while imageY <= covered.maxY {
            label("\(Int(imageY.rounded()))", at: CGPoint(x: 4,
                                                          y: outY(imageY) - fontSize - 5))
            imageY += major
        }
    }

    /// A zoomed image is only understandable together with the fact that its labels still
    /// belong to the full overview image, so the caption states it right in the picture.
    @MainActor
    static func drawZoomCaption(on cg: CGContext, outSize: CGSize) {
        let fontSize = max(11, min(18, outSize.width / 160))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let text = "ZOOM — labels are pixels of the full overview image"
        let size = (text as NSString).size(withAttributes: attrs)
        guard size.width + 12 <= outSize.width else { return }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }

        cg.setFillColor(NSColor(white: 0, alpha: 0.6).cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: outSize.width, height: size.height + 6))
        (text as NSString).draw(at: CGPoint(x: 6, y: 3), withAttributes: attrs)
    }
}
