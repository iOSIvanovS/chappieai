// ComputerUseAccessibilityTests.swift
// ChappieCoreTests
//
// The accessibility tree of a real app cannot be produced in a test, so everything that decides
// WHICH element ends up in the list is pure and covered here: what gets dropped, what order the
// model reads, and which window counts as the target.

import Testing
import Foundation
import CoreGraphics
@testable import ChappieCore

@Suite("Computer Use — accessibility target window")
struct AccessibilityTargetWindowTests {

    private func window(pid: pid_t, layer: Int = 0,
                        x: CGFloat = 0, y: CGFloat = 0,
                        w: CGFloat = 800, h: CGFloat = 600) -> WindowInfo {
        WindowInfo(pid: pid, layer: layer, bounds: CGRect(x: x, y: y, width: w, height: h))
    }

    @Test("The first normal window that is not ours wins")
    func picksTopmostForeignNormalWindow() {
        let windows = [
            window(pid: 100),                              // our own app, topmost
            window(pid: 200),                              // the app the user works in
            window(pid: 300)
        ]
        #expect(AccessibilityReader.pickTarget(from: windows, excluding: 100)?.pid == 200)
    }

    @Test("Panels, bars and layers above the desktop are skipped")
    func skipsNonZeroLayers() {
        let windows = [
            window(pid: 200, layer: 8),                    // floating panel
            window(pid: 300, layer: 0)
        ]
        #expect(AccessibilityReader.pickTarget(from: windows, excluding: 100)?.pid == 300)
    }

    @Test("Slivers are not worth inspecting")
    func skipsTinyWindows() {
        let windows = [
            window(pid: 200, w: 40, h: 20),
            window(pid: 300, w: 400, h: 300)
        ]
        #expect(AccessibilityReader.pickTarget(from: windows, excluding: 100)?.pid == 300)
    }

    @Test("Nothing suitable on screen means no target")
    func noTarget() {
        let windows = [window(pid: 100), window(pid: 200, layer: 5)]
        #expect(AccessibilityReader.pickTarget(from: windows, excluding: 100) == nil)
    }
}

@Suite("Computer Use — element selection")
struct AccessibilitySelectionTests {

    private func el(_ role: String, _ title: String,
                    x: CGFloat, y: CGFloat, w: CGFloat = 40, h: CGFloat = 24) -> AccessibleElement {
        AccessibleElement(role: role, title: title,
                          frame: CGRect(x: x, y: y, width: w, height: h))
    }

    @Test("A frame too thin to be a control is dropped")
    func dropsSlivers() {
        let elements = [
            el("AXButton", "Thin", x: 0, y: 0, w: 200, h: 2),
            el("AXButton", "Real", x: 0, y: 100)
        ]
        let result = AccessibilitySelection.select(elements)
        #expect(result.map(\.title) == ["Real"])
    }

    @Test("A control covering almost the whole window is a container, not a target")
    func dropsContainers() {
        let windowBounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let elements = [
            el("AXButton", "Everything", x: 0, y: 0, w: 980, h: 780),
            el("AXButton", "Small", x: 20, y: 20)
        ]
        let result = AccessibilitySelection.select(elements, windowBounds: windowBounds)
        #expect(result.map(\.title) == ["Small"])
    }

    @Test("A big control that is clearly narrower than the window survives")
    func keepsLargeNonContainer() {
        let windowBounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let elements = [el("AXButton", "Wide", x: 0, y: 0, w: 980, h: 40)]
        let result = AccessibilitySelection.select(elements, windowBounds: windowBounds)
        #expect(result.map(\.title) == ["Wide"])
    }

    @Test("The same control reported twice appears once")
    func dedupes() {
        let elements = [
            el("AXButton", "Run", x: 10, y: 10),
            el("AXButton", "Run", x: 10, y: 10),
            el("AXButton", "Run", x: 10, y: 50)
        ]
        #expect(AccessibilitySelection.select(elements).count == 2)
    }

    @Test("Same frame and different roles are different controls")
    func keepsDistinctRoles() {
        let elements = [
            el("AXButton", "X", x: 10, y: 10),
            el("AXLink", "X", x: 10, y: 10)
        ]
        #expect(AccessibilitySelection.select(elements).count == 2)
    }

    @Test("Reading order: top row first, then left to right")
    func sortsInReadingOrder() {
        let elements = [
            el("AXButton", "bottom", x: 0, y: 500),
            el("AXButton", "topRight", x: 300, y: 10),
            el("AXButton", "topLeft", x: 10, y: 10)
        ]
        #expect(AccessibilitySelection.select(elements).map(\.title) == ["topLeft", "topRight", "bottom"])
    }

    @Test("A few points of vertical drift still counts as the same row")
    func toleratesRowDrift() {
        let elements = [
            el("AXButton", "left", x: 10, y: 10),
            el("AXButton", "right", x: 300, y: 16)
        ]
        #expect(AccessibilitySelection.select(elements).map(\.title) == ["left", "right"])
    }

    @Test("The list is capped and the cap keeps the top of the screen")
    func capsTheList() {
        let elements = (0..<20).map { el("AXButton", "b\($0)", x: 0, y: CGFloat($0) * 40) }
        let result = AccessibilitySelection.select(elements, limit: 5)
        #expect(result.count == 5)
        #expect(result.map(\.title) == ["b0", "b1", "b2", "b3", "b4"])
    }

    @Test("Centre is the geometric middle of the frame")
    func centreOfFrame() {
        let element = el("AXButton", "x", x: 100, y: 200, w: 60, h: 20)
        #expect(element.center == CGPoint(x: 130, y: 210))
    }

    @Test("An untitled control still reads as something in the list")
    func summaryOfUntitled() {
        let element = el("AXButton", "", x: 100, y: 200, w: 60, h: 20)
        #expect(element.summary.contains("(untitled)"))
        #expect(element.summary.contains("130, 210"))
    }

    @Test("A document taller than its window is not a target")
    func dropsScrollingDocument() {
        // Reproduces the real Xcode editor text area: 790 wide, 6611 tall, inside a 1000x800 window.
        let windowBounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let elements = [
            el("AXTextArea", "Chappie — Overall Project Architecture", x: 200, y: 30, w: 790, h: 6611),
            el("AXButton", "Issues", x: 20, y: 100)
        ]
        let result = AccessibilitySelection.select(elements, windowBounds: windowBounds)
        #expect(result.map(\.title) == ["Issues"])
    }

    @Test("A control whose centre falls outside the window is dropped")
    func dropsOffWindowCentre() {
        let windowBounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let elements = [
            el("AXButton", "below", x: 100, y: 900),        // centre at y 912, past the window
            el("AXButton", "inside", x: 100, y: 100)
        ]
        let result = AccessibilitySelection.select(elements, windowBounds: windowBounds)
        #expect(result.map(\.title) == ["inside"])
    }

    @Test("Without window bounds nothing is dropped for being off-window")
    func offWindowRuleNeedsBounds() {
        let elements = [el("AXButton", "below", x: 100, y: 900)]
        #expect(AccessibilitySelection.select(elements).count == 1)
    }
}

@Suite("Computer Use — element title")
struct AccessibleElementTitleTests {

    @Test("A short name passes through untouched")
    func shortNameUnchanged() {
        let element = AccessibleElement(role: "AXButton", title: "Run",
                                        frame: CGRect(x: 0, y: 0, width: 40, height: 24))
        #expect(element.title == "Run")
    }

    @Test("Document text reported as the value is cut to a readable name")
    func longTextIsCut() {
        // An AXTextArea reports its whole document through kAXValueAttribute.
        let document = String(repeating: "line of the document\n", count: 500)
        let element = AccessibleElement(role: "AXTextArea", title: document,
                                        frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        #expect(element.title.count == AccessibleElement.maxTitleLength + 1)   // + the ellipsis
        #expect(element.title.hasSuffix("…"))
        #expect(!element.title.contains("\n"))
    }

    @Test("Line breaks and runs of spaces collapse into one line")
    func whitespaceCollapsed() {
        let element = AccessibleElement(role: "AXTextField", title: "  first\n\nsecond   third  ",
                                       frame: CGRect(x: 0, y: 0, width: 40, height: 24))
        #expect(element.title == "first second third")
    }
}

@Suite("Computer Use — accessibility roles")
struct AccessibilityRoleTests {

    @Test("Containers are not interactive targets")
    func containersExcluded() {
        for role in ["AXWindow", "AXGroup", "AXScrollArea", "AXApplication"] {
            #expect(!AccessibilityRoles.interactive.contains(role))
        }
    }

    @Test("The controls a user clicks are included")
    func controlsIncluded() {
        for role in ["AXButton", "AXLink", "AXTextField", "AXCheckBox", "AXMenuItem", "AXCell"] {
            #expect(AccessibilityRoles.interactive.contains(role))
        }
    }

    @Test("Outline rows and scrollbar thumbs are not listed separately")
    func noiseRolesExcluded() {
        for role in ["AXRow", "AXValueIndicator"] {
            #expect(!AccessibilityRoles.interactive.contains(role))
        }
    }
}
