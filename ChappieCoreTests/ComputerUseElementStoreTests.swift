// ComputerUseElementStoreTests.swift
// ChappieCoreTests
//
// Numbers on a screenshot are the one thing standing between "click the small window button" and
// "click whatever is a few pixels away from it". What is tested here is that a number leads back to
// the EXACT frame it was drawn from, that it stops working once it can no longer be trusted, and
// that the text next to the picture promises nothing the code does not do.

import Testing
import Foundation
import CoreGraphics
@testable import ChappieCore

// MARK: - Helpers

private func element(_ role: String, _ title: String,
                     x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> AccessibleElement {
    AccessibleElement(role: role, title: title,
                      frame: CGRect(x: x, y: y, width: w, height: h))
}

private func mark(_ number: Int, _ element: AccessibleElement) -> ElementMark {
    ElementMark(number: number, element: element, imageRect: element.frame)
}

// MARK: - Store

@Suite("Marked screenshot store")
struct MarkedScreenshotStoreTests {

    @Test("Every screenshot gets its own id, and the store keeps the last one")
    func idsAndLatest() {
        let store = MarkedScreenshotStore()
        #expect(store.latest() == nil)

        let first = store.record(applicationName: "Xcode", marks: [])
        let second = store.record(applicationName: "Xcode", marks: [])

        #expect(second.id == first.id + 1)
        #expect(store.latest()?.id == second.id)
    }

    @Test("A number resolves to the element it labelled")
    func resolves() {
        let store = MarkedScreenshotStore()
        let close = element("AXButton", "close", x: 100, y: 200, w: 12, h: 12)
        let zoom  = element("AXButton", "Zoom",  x: 300, y: 400, w: 24, h: 24)
        store.record(applicationName: "Xcode", marks: [mark(1, close), mark(2, zoom)])

        let shot = store.latest()
        #expect(shot?.element(number: 2)?.element.title == "Zoom")
        #expect(shot?.element(number: 3) == nil)
    }

    @Test("Clearing forgets the numbers, which is how a stale click is prevented")
    func clearing() {
        let store = MarkedScreenshotStore()
        store.record(applicationName: "Xcode",
                     marks: [mark(1, element("AXButton", "close", x: 0, y: 0, w: 12, h: 12))])
        store.clear()
        #expect(store.latest() == nil)
    }
}

// MARK: - Lookup

@Suite("Element lookup")
struct ElementLookupTests {

    @Test("The click point is the AX centre, used as-is — no coordinate conversion")
    func centreUnchanged() {
        let store = MarkedScreenshotStore()
        // A window button, top-left of the screen, exactly the kind a pixel guess misses.
        let close = element("AXButton", "close", x: 12, y: 8, w: 12, h: 12)
        store.record(applicationName: "Xcode", pid: 4242, marks: [mark(1, close)])

        switch ToolExecutionService.resolveElement(1, in: store) {
        case .point(let point, let description, let pid):
            #expect(point == CGPoint(x: 18, y: 14))
            #expect(description.contains("close"))
            #expect(description.contains("Xcode"))
            // The owning process rides along, so typing can activate it without guessing.
            #expect(pid == 4242)
        case .failure(let message):
            Issue.record("expected a point, got: \(message)")
        }
    }

    @Test("Without a numbered screenshot the model is told how to get one")
    func noScreenshot() {
        let store = MarkedScreenshotStore()
        switch ToolExecutionService.resolveElement(4, in: store) {
        case .point:
            Issue.record("expected a failure")
        case .failure(let message):
            #expect(message.contains("marks:true"))
        }
    }

    @Test("An unknown number reports which numbers do exist, instead of clicking something else")
    func unknownNumber() {
        let store = MarkedScreenshotStore()
        store.record(applicationName: "Finder",
                     marks: [mark(1, element("AXButton", "close", x: 0, y: 0, w: 12, h: 12)),
                             mark(2, element("AXButton", "Zoom", x: 20, y: 0, w: 12, h: 12))])
        switch ToolExecutionService.resolveElement(9, in: store) {
        case .point:
            Issue.record("expected a failure")
        case .failure(let message):
            #expect(message.contains("no element 9"))
            #expect(message.contains("1, 2"))
        }
    }

    @Test("A window that reported nothing says so plainly")
    func emptyList() {
        let store = MarkedScreenshotStore()
        store.record(applicationName: "SomeCanvasApp", marks: [])
        switch ToolExecutionService.resolveElement(1, in: store) {
        case .point:
            Issue.record("expected a failure")
        case .failure(let message):
            #expect(message.contains("Available numbers: none"))
        }
    }
}

// MARK: - Text that accompanies the picture

@Suite("Element list text")
struct ElementListTextTests {

    private let close = AccessibleElement(role: "AXButton", title: "close",
                                          frame: CGRect(x: 12, y: 8, width: 12, height: 12))

    @Test("The list names the picture, promises the exact centre, and numbers every element")
    func fullList() {
        let shot = MarkedScreenshot(id: 3, applicationName: "Xcode", marks: [mark(1, close)])
        let text = ToolExecutionService.elementListText(action: nil, shot: shot,
                                                        shown: shot.marks, isCrop: false, note: "")
        #expect(text.contains("Screenshot #3 of Xcode"))
        #expect(text.contains("1 interactive controls"))
        #expect(text.contains("computer_click(element: 7)"))
        #expect(text.contains("screenshot #3 only"))
        #expect(text.contains("[1] AXButton \"close\" 12×12"))
        #expect(!text.lowercased().contains("crop"))
    }

    @Test("A crop says how much of the numbered set it shows")
    func cropList() {
        let shot = MarkedScreenshot(id: 5, applicationName: "Xcode", marks: [mark(1, close)])
        let text = ToolExecutionService.elementListText(action: "Clicked [1] AXButton \"close\" in Xcode.",
                                                        shot: shot, shown: shot.marks,
                                                        isCrop: true, note: "")
        #expect(text.hasPrefix("Clicked [1]"))
        #expect(text.contains("1 of 1 numbered controls are inside this crop"))
    }

    @Test("No controls at all points the model back to the grid")
    func emptyList() {
        let shot = MarkedScreenshot(id: 7, applicationName: "SomeCanvasApp", marks: [])
        let text = ToolExecutionService.elementListText(action: nil, shot: shot,
                                                        shown: [], isCrop: false, note: "")
        #expect(text.contains("no interactive controls"))
        #expect(text.contains("computer_click(x:, y:)"))
    }

    @Test("A caveat from the reader reaches the model instead of an unexplained empty picture")
    func note() {
        let shot = MarkedScreenshot(id: 8, applicationName: "this screen", marks: [])
        let text = ToolExecutionService.elementListText(action: nil, shot: shot, shown: [],
                                                        isCrop: false,
                                                        note: "Accessibility permission is not granted.")
        #expect(text.hasPrefix("Accessibility permission is not granted."))
    }

    @Test("Only the marks inside the captured area are drawn and listed")
    func visibility() {
        let inside  = mark(1, close)
        let outside = mark(2, AccessibleElement(role: "AXButton", title: "far away",
                                                frame: CGRect(x: 5000, y: 5000, width: 20, height: 20)))
        let shown = ElementMarks.visible([inside, outside],
                                         in: CGRect(x: 0, y: 0, width: 1440, height: 900))
        #expect(shown.map(\.number) == [1])
    }
}

// MARK: - Crop geometry

@Suite("Screenshot crop plan")
struct ScreenshotCropPlanTests {

    @Test("Without a region the crop covers the whole overview image")
    func wholeScreen() {
        let plan = ToolExecutionService.cropPlan(nativeSize: CGSize(width: 2880, height: 1800), region: nil)
        #expect(plan.pixels == CGRect(x: 0, y: 0, width: 2880, height: 1800))
        // 2880 native pixels downscale to a 1440-px overview: half scale.
        #expect(plan.covered == CGRect(x: 0, y: 0, width: 1440, height: 900))
    }

    @Test("A region is cut from native pixels and reported in overview pixels")
    func zoom() {
        let plan = ToolExecutionService.cropPlan(nativeSize: CGSize(width: 2880, height: 1800),
                                                 region: CGRect(x: 100, y: 100, width: 200, height: 100))
        // Overview pixel → native pixel is ×2; edges snap outward to whole native pixels.
        #expect(plan.pixels == CGRect(x: 200, y: 200, width: 400, height: 200))
        #expect(plan.covered == CGRect(x: 100, y: 100, width: 200, height: 100))
    }

    @Test("A region hanging off the screen is clamped, never negative")
    func clamped() {
        let plan = ToolExecutionService.cropPlan(nativeSize: CGSize(width: 2880, height: 1800),
                                                 region: CGRect(x: 1400, y: 860, width: 400, height: 400))
        #expect(plan.pixels.maxX <= 2880)
        #expect(plan.pixels.maxY <= 1800)
        #expect(plan.pixels.minX >= 0)
        #expect(plan.pixels.minY >= 0)
    }
}

// MARK: - Result routing

@Suite("Numbered screenshot routing")
struct MarkedResultRoutingTests {

    @Test("All four computer tools may answer with text plus a picture")
    func allowed() {
        for tool in ["computer_screenshot", "computer_click", "computer_scroll", "computer_type"] {
            #expect(ToolExecutionService.textAndImageTools.contains(tool))
        }
        // Adding the computer tools must not remove the document readers.
        for tool in ToolExecutionService.documentImageTools {
            #expect(ToolExecutionService.textAndImageTools.contains(tool))
        }
    }

    @Test("A numbered screenshot survives the size gate, and only from a listed tool")
    func guardPasses() {
        let result = ToolImageResult(
            text: "Screenshot #1 of Xcode: 2 interactive controls are numbered on the picture.",
            images: [.init(label: "Screenshot #1", dataURI: "data:image/jpeg;base64,AAAA")]
        ).encoded()
        #expect(OutputGuard.apply(toolName: "computer_screenshot", output: result) == result)

        // The picture is exempt from the text limit, the list is not: an element list that somehow
        // grew to a novel would still be refused.
        let bloated = ToolImageResult(
            text: String(repeating: "A", count: OutputGuard.readLimit + 1),
            images: [.init(label: "Screenshot #2", dataURI: "data:image/jpeg;base64,AAAA")]
        ).encoded()
        #expect(OutputGuard.apply(toolName: "computer_screenshot", output: bloated).contains("NOT PASSED"))
    }
}
