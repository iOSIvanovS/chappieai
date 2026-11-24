// ComputerUseAXTargetTests.swift
// ChappieCoreTests
//
// The pure half of accessibility targeting: where a click lands inside a frame, what counts as
// visible, and how "role:name#n" resolves. These are the numbers the directory prints and the
// action tool fires, so a change here must fail loudly.

import Testing
import Foundation
import CoreGraphics
import ApplicationServices
@testable import ChappieCore

@Suite("AX aim point")
struct AXAimPointTests {

    @Test("A disclosure triangle is hit on its glyph, at the leading edge of its frame")
    func twist() {
        // Measured on Xcode's outline: a 15x24 pt frame whose triangle is drawn on the left.
        let box = CGRect(x: 11, y: 121, width: 15, height: 24)
        let point = AXElementInfo.aimPoint(in: box, role: "twist")
        #expect(point.x == 11 + 3.75)
        #expect(point.y == 133)
        #expect(point.x < box.midX)                 // the centre of this frame is empty cell
    }

    @Test("A wide checkbox is hit on the box, not on the middle of its label")
    func checkbox() {
        let box = CGRect(x: 0, y: 0, width: 400, height: 20)
        #expect(AXElementInfo.aimPoint(in: box, role: "check").x == 10)   // capped at 10 pt
    }

    @Test("Everything else is hit dead centre")
    func centre() {
        let box = CGRect(x: 100, y: 50, width: 80, height: 30)
        #expect(AXElementInfo.aimPoint(in: box, role: "button") == CGPoint(x: 140, y: 65))
        #expect(AXElementInfo.aimPoint(in: box, role: "row") == CGPoint(x: 140, y: 65))
    }
}

@Suite("AX visibility")
struct AXVisibilityTests {

    private let display = CGRect(x: 0, y: 0, width: 1000, height: 800)

    @Test("Without a window the whole display is visible")
    func noWindow() {
        #expect(AXVisibility.visibleArea(window: nil, display: display) == display)
    }

    @Test("A window hanging over the edge contributes only what is on screen")
    func windowOverEdge() {
        let window = CGRect(x: -200, y: 100, width: 400, height: 300)
        let area = AXVisibility.visibleArea(window: window, display: display)
        #expect(area == CGRect(x: 0, y: 100, width: 200, height: 300))
    }

    @Test("A window entirely off screen leaves nothing visible")
    func windowAway() {
        let window = CGRect(x: 2000, y: 0, width: 400, height: 300)
        #expect(AXVisibility.visibleArea(window: window, display: display).isEmpty)
    }

    @Test("A scroll area narrows what its children may occupy")
    func scrolledAway() {
        let scroll = CGRect(x: 0, y: 0, width: 300, height: 400)
        let clip = AXVisibility.narrow(display, to: scroll)
        #expect(AXVisibility.fraction(of: CGPoint(x: 35, y: 20), clip: clip, display: display) != nil)
        #expect(AXVisibility.fraction(of: CGPoint(x: 35, y: 910), clip: clip, display: display) == nil)
        // Inside the scroll area but outside the display is also refused.
        #expect(AXVisibility.fraction(of: CGPoint(x: 1200, y: 20), clip: clip, display: display) == nil)
    }

    @Test("A visible point becomes a monitor fraction")
    func fraction() {
        let clip = AXVisibility.narrow(display, to: CGRect(x: 100, y: 100, width: 400, height: 400))
        let point = AXVisibility.fraction(of: CGPoint(x: 300, y: 300), clip: clip, display: display)
        #expect(point == CGPoint(x: 0.3, y: 0.375))
    }
}

@Suite("AX target parsing")
struct AXTargetParseTests {

    @Test("role:name splits on the first colon only")
    func simple() throws {
        let spec = try #require(AXTargetResolver.parse("twist:ViewModels"))
        #expect(spec.role == "twist")
        #expect(spec.name == "ViewModels")
        #expect(spec.ordinal == nil)
    }

    @Test("A name may contain colons")
    func colonInName() throws {
        let spec = try #require(AXTargetResolver.parse("row:Chappie:Notes"))
        #expect(spec.name == "Chappie:Notes")
    }

    @Test("#n picks among equal matches")
    func ordinal() throws {
        let spec = try #require(AXTargetResolver.parse("row:Chappie#2"))
        #expect(spec.name == "Chappie")
        #expect(spec.ordinal == 2)
    }

    @Test("A long role name is normalised to the short one the directory prints")
    func role() throws {
        #expect(try #require(AXTargetResolver.parse("AXButton:OK")).role == "button")
        #expect(try #require(AXTargetResolver.parse("Button:OK")).role == "button")
    }

    @Test("Nonsense is refused rather than guessed")
    func invalid() {
        #expect(AXTargetResolver.parse("ViewModels") == nil)
        #expect(AXTargetResolver.parse("twist:") == nil)
        #expect(AXTargetResolver.parse(":ViewModels") == nil)
    }
}

@Suite("AX target resolution")
struct AXTargetResolveTests {

    private func element(_ role: String, _ name: String, y: CGFloat) -> AXElementInfo {
        AXElementInfo(role: role, name: name, center: CGPoint(x: 0.1, y: y),
                      sizePoints: CGSize(width: 15, height: 24), note: "")
    }

    private var tree: [AXElementInfo] {
        [
            element("twist", "Chappie", y: 0.10),
            element("row", "Chappie", y: 0.10),
            element("twist", "ViewModels", y: 0.12),
            element("row", "ViewModelsTests", y: 0.13),
            element("button", "Отмена", y: 0.90)
        ]
    }

    @Test("Role and name together identify exactly one element")
    func exact() {
        // The same name exists as a twist and as a row: the role is what disambiguates.
        #expect(AXTargetResolver.resolve("twist:ViewModels", in: tree) == .found(2))
        #expect(AXTargetResolver.resolve("row:Chappie", in: tree) == .found(1))
    }

    @Test("An exact match wins over a longer name that contains it")
    func exactBeatsPartial() {
        // "ViewModels" must never quietly become "ViewModelsTests" while both are listed.
        let local = [element("row", "ViewModelsTests", y: 0.2), element("row", "ViewModels", y: 0.1)]
        #expect(AXTargetResolver.resolve("row:ViewModels", in: local) == .found(1))
    }

    @Test("A partial name is used only when nothing matches exactly")
    func partial() {
        #expect(AXTargetResolver.resolve("row:ViewModelsTes", in: tree) == .found(3))
    }

    @Test("Two identical targets are ambiguous, not silently the first")
    func ambiguous() {
        let twins = [element("row", "Chappie", y: 0.10), element("row", "Chappie", y: 0.30)]
        #expect(AXTargetResolver.resolve("row:Chappie", in: twins) == .ambiguous([0, 1]))
        #expect(AXTargetResolver.resolve("row:Chappie#2", in: twins) == .found(1))
    }

    @Test("An ordinal past the end is a miss, not a crash")
    func ordinalOutOfRange() {
        // Both roles that carry the name are offered back, so a wrong # is easy to correct.
        #expect(AXTargetResolver.resolve("row:Chappie#3", in: tree) == .notFound([0, 1]))
    }

    @Test("A miss reports nearby names so a wrong role is visible")
    func notFound() {
        guard case .notFound(let candidates) = AXTargetResolver.resolve("button:Chappie", in: tree) else {
            Issue.record("expected a miss")
            return
        }
        #expect(candidates.contains(0) || candidates.contains(1))
    }

    @Test("A malformed target comes back as a reason, not as a miss")
    func invalid() {
        guard case .invalid(let reason) = AXTargetResolver.resolve("ViewModels", in: tree) else {
            Issue.record("expected invalid")
            return
        }
        #expect(reason.contains("role:name"))
    }

    @Test("Case and spacing do not matter, so a slip never becomes a refusal")
    func lenient() {
        #expect(AXTargetResolver.resolve("twist:viewmodels", in: tree) == .found(2))
        #expect(AXTargetResolver.resolve("TWIST: ViewModels ", in: tree) == .found(2))
    }
}

@Suite("AX action names")
struct AXActionNameTests {

    @Test("Short names are what the directory prints")
    func short() {
        #expect(AXActionName.short("AXPress") == "press")
        #expect(AXActionName.short("AXShowMenu") == "menu")
        #expect(AXActionName.short("AXIncrement") == "inc")
        // An unknown action still reads as something.
        #expect(AXActionName.short("AXSomethingNew") == "somethingnew")
    }

    @Test("A multi-line action name stays on one line and is bounded")
    func noisyName() {
        let noisy = "Name:move previous\ntarget:0x0\nselector:(null)\r\nname:move next"
        let short = AXActionName.short(noisy)
        #expect(!short.contains("\n") && !short.contains("\r"))
        #expect(short.count <= AXActionName.maxShortLength)
        #expect(AXActionName.short("\n") == "?")
    }

    @Test("Listed actions are deduplicated and capped")
    func listedDedupe() {
        #expect(AXActionName.listed(["AXPress", "AXPress", "AXShowMenu"]) == ["press", "menu"])
        let many = (1...9).map { "AXCustom\($0)" }
        let listed = AXActionName.listed(many)
        #expect(listed.count == 7)
        #expect(listed.last == "+3")
    }

    @Test("oneLine collapses whitespace and truncates with an ellipsis")
    func oneLine() {
        #expect(AXText.oneLine("a \n\t b", limit: 10) == "a b")
        #expect(AXText.oneLine("abcdefghij", limit: 5) == "abcd…")
    }

    @Test("The model's word resolves to the element's own action, whatever its case")
    func match() {
        let declared = ["AXPress", "AXShowMenu"]
        #expect(AXActionName.match("press", in: declared) == "AXPress")
        #expect(AXActionName.match("AXPress", in: declared) == "AXPress")
        #expect(AXActionName.match("PRESS", in: declared) == "AXPress")
        #expect(AXActionName.match("menu", in: declared) == "AXShowMenu")
        #expect(AXActionName.match("inc", in: declared) == nil)
    }
}

@Suite("AX directory line")
struct AXDirectoryLineTests {

    private func info(actions: [String]?, enabled: Bool = true, note: String = "") -> AXElementInfo {
        AXElementInfo(role: "twist", name: "ViewModels", center: CGPoint(x: 0.0272, y: 0.2195),
                      sizePoints: CGSize(width: 15, height: 24), note: note,
                      actions: actions, enabled: enabled)
    }

    @Test("Declared actions are printed in short form")
    func actions() {
        let line = AXElementInfo.line(for: info(actions: ["AXPress", "AXShowMenu"]), index: 0)
        #expect(line.contains("[press menu]"))
    }

    @Test("A disabled control says so and never lists actions")
    func disabled() {
        let line = AXElementInfo.line(for: info(actions: ["AXPress"], enabled: false), index: 0)
        #expect(line.contains("disabled"))
        #expect(!line.contains("[press"))
    }

    @Test("An unread action list is marked unknown, not empty")
    func unknown() {
        #expect(AXElementInfo.line(for: info(actions: nil), index: 0).contains("[?]"))
        #expect(AXElementInfo.line(for: info(actions: []), index: 0).contains("no-actions"))
    }
}
