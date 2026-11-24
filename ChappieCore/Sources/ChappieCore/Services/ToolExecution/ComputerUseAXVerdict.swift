// ComputerUseAXVerdict.swift
// ChappieCore
//
// WHY THIS FILE:
// The sentence printed after an action is the only evidence the model has that the action did
// anything, so it must not be a criterion applied where it cannot see the thing it was meant to
// see. Comparing the element's state before and after is a real test for a press, a twist or a
// row. It is NOT a test for a menu: opening one leaves the button untouched and draws a separate
// window, so "State unchanged — retry with mouse" was reported for a menu that had just opened.
// A real mouse click sits in between: AX is not told about every control's click either.
//
// Three cases, one rule, pure, so the wording is pinned by tests instead of by a live run.

import Foundation

/// What was fired, as far as the reply's wording is concerned.
enum AXActionKind {
    /// One of the element's own AX actions, by its full AX name (`AXPress`, `AXShowMenu`, …).
    case ax(String)
    /// A real left click on the element's own point.
    case mouse
    /// Two real left clicks.
    case doubleClick
}

enum AXActionVerdict {

    /// The sentence that follows the description of what was sent. `before` and `after` are
    /// `AXRead.stateSummary` values, taken around the action.
    static func note(kind: AXActionKind, before: String, after: String) -> String {
        if before != after {
            return "State changed: \(before) → \(after)."
        }
        switch kind {
        case .ax(let name) where AXActionName.short(name) == "menu":
            return "State unchanged (\(after)). Opening a menu never changes the button's own "
                + "state, so this says nothing about whether it opened: look at the picture for "
                + "an open menu. If none appeared, retry with action: mouse."
        case .ax:
            return "State unchanged (\(after)) — an AX action can still have taken effect outside "
                + "this element's own state, so check the picture; if nothing moved, retry with "
                + "action: mouse."
        case .mouse, .doubleClick:
            return "State unchanged (\(after)) — not every control reports a click in its own "
                + "state, so check the picture."
        }
    }
}
