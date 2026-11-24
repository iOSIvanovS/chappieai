// ComputerUseAXVerdictTests.swift
// ChappieCoreTests
//
// WHY: the sentence after an action is the model's only evidence that it did anything. A criterion
// applied where it cannot see the result is worse than no criterion, so each of the three cases is
// pinned by text: a change always wins, an unchanged menu is silent about failure, an unchanged
// press points at the mouse fallback, and an unchanged click does not tell the model to click again.

import Testing
@testable import ChappieCore

@Suite("AX action verdict")
struct AXActionVerdictTests {

    @Test("A state change is reported whatever the action was")
    func stateChangeWins() {
        let note = AXActionVerdict.note(kind: .ax("AXShowMenu"),
                                        before: "value=0 enabled=true",
                                        after: "value=1 enabled=true")
        #expect(note == "State changed: value=0 enabled=true → value=1 enabled=true.")
    }

    @Test("An unchanged menu does not report itself as a failure")
    func menuMakesNoClaim() {
        let note = AXActionVerdict.note(kind: .ax("AXShowMenu"),
                                        before: "value=0 enabled=true",
                                        after: "value=0 enabled=true")
        #expect(note.contains("Opening a menu never changes"))
        #expect(!note.contains("State changed"))
        #expect(note.contains("retry with action: mouse"))
    }

    @Test("An unchanged press points at the mouse fallback")
    func pressSuggestsMouse() {
        let note = AXActionVerdict.note(kind: .ax("AXPress"), before: "value=0", after: "value=0")
        #expect(note.contains("State unchanged (value=0)"))
        #expect(note.contains("retry with action: mouse"))
        #expect(!note.contains("Opening a menu"))
    }

    @Test("An unchanged click does not tell the model to click again")
    func clickDoesNotSuggestMouse() {
        let note = AXActionVerdict.note(kind: .mouse,
                                        before: "no readable state",
                                        after: "no readable state")
        #expect(note.contains("not every control reports a click"))
        #expect(!note.contains("retry with action: mouse"))
    }

    @Test("A double click is worded as a click")
    func doubleClickUsesClickWording() {
        let note = AXActionVerdict.note(kind: .doubleClick, before: "v=1", after: "v=1")
        #expect(note.contains("not every control reports a click"))
        #expect(!note.contains("Opening a menu"))
    }
}
