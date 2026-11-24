// ComputerUseAccessibilityTests.swift
// ChappieCoreTests
//
// The AX tree cannot be read in a unit test, so these tests cover the half that can be: turning
// element info into the directory text, and the role whitelist that decides what is aimable at all.
// The text is a contract with the model — it copies the digits out of it — so it is pinned here.

import Testing
import Foundation
import CoreGraphics
import ApplicationServices
@testable import ChappieCore

@Suite("AX directory formatting")
struct AXDirectoryFormatTests {

    private func element(
        _ name: String,
        role: String = "twist",
        x: CGFloat = 0.25,
        y: CGFloat = 0.5,
        w: CGFloat = 15,
        h: CGFloat = 24,
        note: String = ""
    ) -> AXElementInfo {
        AXElementInfo(role: role, name: name, center: CGPoint(x: x, y: y),
                      sizePoints: CGSize(width: w, height: h), note: note)
    }

    @Test("Every element gets one numbered line, in the order given")
    func lines() {
        let text = AXElementInfo.format(
            [element("Alpha"), element("Beta", role: "row"), element("Gamma")],
            appName: "Xcode", monitor: 0, omitted: 0
        )
        let lines = text.split(separator: "\n")
        #expect(lines.count == 4)                       // header + three elements
        #expect(lines[1].contains("[1] twist"))
        #expect(lines[1].contains("Alpha"))
        #expect(lines[2].contains("[2] row"))
        #expect(lines[3].contains("[3] twist"))
    }

    @Test("The centre is printed as fractions with four decimals, ready to copy")
    func fractions() {
        let text = AXElementInfo.format(
            [element("Chevron", x: 0.0108, y: 0.1225)],
            appName: "Xcode", monitor: 0, omitted: 0
        )
        #expect(text.contains("c=0.0108,0.1225"))
        // Aiming data must not be presented as pixels.
        #expect(!text.contains("px"))
    }

    @Test("Size in points and the disclosure state ride along")
    func sizeAndNote() {
        let text = AXElementInfo.format(
            [element("ViewModels", w: 15, h: 24, note: "collapsed")],
            appName: "Xcode", monitor: 0, omitted: 0
        )
        #expect(text.contains("15x24pt"))
        #expect(text.contains("collapsed"))
    }

    @Test("A long name is cut with an ellipsis instead of wrapping the line")
    func longName() {
        let long = String(repeating: "VeryLongFileName", count: 6)
        let text = AXElementInfo.format([element(long)], appName: "Xcode", monitor: 0, omitted: 0)
        #expect(text.contains("…"))
        #expect(!text.contains(long))
        // One header plus one element: the name never spills onto its own line.
        #expect(text.split(separator: "\n").count == 2)
    }

    @Test("Newlines inside a name are flattened so a row stays one line")
    func flattened() {
        let text = AXElementInfo.format([element("Two\nLines")], appName: "Xcode", monitor: 0, omitted: 0)
        #expect(text.contains("Two Lines"))
        #expect(text.split(separator: "\n").count == 2)
    }

    @Test("Truncation is reported, so the model knows the list is partial")
    func omitted() {
        let text = AXElementInfo.format([element("A")], appName: "Xcode", monitor: 0, omitted: 9)
        #expect(text.contains("of 10"))
    }

    @Test("An empty tree says so and points at the fallbacks")
    func empty() {
        let text = AXElementInfo.format([], appName: "jsPaint", monitor: 1, omitted: 0)
        #expect(text.contains("no aimable elements"))
        #expect(text.contains("jsPaint"))
        #expect(text.contains("monitor 1"))
        #expect(text.contains("computer_zoom"))
    }
}

@Suite("AX role selection")
struct AXRoleSelectionTests {

    @Test("Controls a human clicks are aimable")
    func targets() {
        for role in [kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole,
                     kAXMenuItemRole, kAXTextFieldRole, "AXLink", "AXSearchField"] {
            #expect(AXElementInfo.targetRoles.contains(role))
        }
    }

    @Test("Containers are not aimable: their centre means nothing as a target")
    func containers() {
        for role in [kAXGroupRole, kAXWindowRole, kAXOutlineRole, kAXRowRole, kAXCellRole,
                     kAXScrollAreaRole, kAXSplitGroupRole] {
            #expect(!AXElementInfo.targetRoles.contains(role))
        }
    }

    @Test("Roles are shortened to the labels the directory prints")
    func short() {
        #expect(AXElementInfo.shortRole(kAXTextFieldRole) == "field")
        #expect(AXElementInfo.shortRole("AXSearchField") == "field")
        #expect(AXElementInfo.shortRole("AXLink") == "link")
        #expect(AXElementInfo.shortRole(kAXButtonRole) == "button")
        #expect(AXElementInfo.shortRole(kAXPopUpButtonRole) == "popup")
        #expect(AXElementInfo.shortRole(kAXCheckBoxRole) == "check")
        // An unknown role still yields something readable rather than the raw identifier.
        #expect(AXElementInfo.shortRole("AXSomethingNew") == "somethingnew")
    }
}
