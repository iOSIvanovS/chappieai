// ComputerUseAccessibility.swift
// ChappieCore
//
// WHY THIS FILE:
// The overview frame is capped at 1440 px, so a 10 pt disclosure chevron is about two pixels wide:
// its shape is readable, its position is not. The accessibility tree answers exactly that question —
// every control already carries its exact frame — so the tree becomes a compact directory of one
// line per target, each with the geometric CENTRE as a fraction of the monitor, ready to paste
// straight into computer_move_to. Nothing is drawn on the picture: the directory is a reference
// that rides beside the frame in the same tool result, so the model reads the screen by eye and
// aims by numbers.
//
// This file holds the RESULT of a walk (the model, the role tables, and the text the model reads).
// The walk itself lives in ComputerUseAXWalker.swift, the AX calls in ComputerUseAXRead.swift, and
// the pure targeting arithmetic in ComputerUseAXTarget.swift.

import Foundation
import CoreGraphics
import AppKit
import ApplicationServices

/// Text read from an application, reduced to what fits one line of the directory.
enum AXText {

    /// CR, LF and tabs become spaces, runs of spaces collapse into one, and an over-long string is
    /// cut with an ellipsis so the result never exceeds `limit` characters. Xcode's toolbar buttons
    /// hand out labels and action names that carry a whole debug description with newlines in it
    /// ("name:move previous\ntarget:0x0\nselector:(null)"); printed raw those break the
    /// one-element-per-line table, shift every following row, and are charged as tokens again on
    /// every later request. A tab stops the newline check just as well as a space does.
    static func oneLine(_ raw: String, limit: Int) -> String {
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > limit, limit > 1 else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }
}

/// One aimable control, already reduced to the numbers and the vocabulary the model needs.
struct AXElementInfo: Equatable {
    /// "twist" for a disclosure chevron, otherwise the short role name of the control.
    let role: String
    /// Visible label: the row's file name, the button's title, the field's current value.
    let name: String
    /// Geometric centre of the frame, as a fraction of the monitor (0...1, top-left origin).
    /// Informational: the point a click actually uses is computed per role — see aimPoint.
    let center: CGPoint
    /// Size in points — tells the model whether it is aiming at a chevron or a whole row.
    let sizePoints: CGSize
    /// "expanded" / "collapsed" for chevrons, the item kind for rows, empty otherwise.
    let note: String
    /// Full AX action names the element declares; nil when the walk could not ask (budget ran out).
    /// A declared action is not a promise: AXPress can be listed and still do nothing.
    var actions: [String]? = nil
    /// False when AXEnabled says the control is greyed out: it declares actions and ignores them.
    var enabled: Bool = true
    /// Position in the published directory, 1-based, so "role:name#n" can be resolved by the model.
    var id: Int = 0
    /// Live element, for the resolver and for state comparison. Not part of the text.
    var element: AXUIElement? = nil

    static func == (lhs: AXElementInfo, rhs: AXElementInfo) -> Bool {
        lhs.role == rhs.role && lhs.name == rhs.name && lhs.center == rhs.center
            && lhs.sizePoints == rhs.sizePoints && lhs.note == rhs.note
            && lhs.actions == rhs.actions && lhs.enabled == rhs.enabled && lhs.id == rhs.id
    }

    /// The target string this element is addressed by: "twist:ViewModels".
    var reference: String { "\(role):\(name)" }

    /// True when the element declares nothing to do; the model must fall back to a plain click.
    var actionHint: String {
        guard enabled else { return "disabled" }
        guard let actions else { return "[?]" }
        let listed = AXActionName.listed(actions)
        return listed.isEmpty ? "no-actions" : "[" + listed.joined(separator: " ") + "]"
    }
}

extension AXElementInfo {

    /// Roles a human would click. Containers are excluded on purpose: they carry no label and their
    /// centre is meaningless as a target.
    static let targetRoles: Set<String> = [
        kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole,
        kAXPopUpButtonRole, kAXMenuButtonRole, kAXMenuItemRole,
        kAXMenuBarItemRole, "AXLink", kAXTextFieldRole,
        kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
        kAXSliderRole, kAXIncrementorRole, kAXColorWellRole
    ]

    static func shortRole(_ role: String) -> String {
        switch role {
        case kAXTextFieldRole, "AXSearchField":             return "field"
        case kAXTextAreaRole:                               return "text"
        case kAXCheckBoxRole:                               return "check"
        case kAXRadioButtonRole:                            return "radio"
        case kAXPopUpButtonRole:                            return "popup"
        case kAXMenuButtonRole:                             return "menu"
        case kAXMenuItemRole:                               return "item"
        case kAXMenuBarItemRole:                            return "menubar"
        case "AXLink":                                      return "link"
        case kAXSliderRole:                                 return "slider"
        case kAXColorWellRole:                              return "color"
        default:
            return role.hasPrefix("AX") ? role.dropFirst(2).lowercased() : role.lowercased()
        }
    }

    /// The directory the model reads. Pure: same input, same text, no AX access — which is what the
    /// tests pin down.
    static func format(
        _ elements: [AXElementInfo],
        appName: String,
        monitor: Int,
        omitted: Int
    ) -> String {
        guard !elements.isEmpty else {
            return "AX directory — app \"\(appName)\": no aimable elements found on monitor \(monitor). "
                + "Aim by eye from the frame, or use computer_zoom."
        }
        var lines = [
            "AX directory — app \"\(appName)\", \(elements.count) element"
                + (elements.count == 1 ? "" : "s")
                + (omitted > 0 ? " (of \(elements.count + omitted), nearest to the top first)" : "")
                + ". c=(x,y) is the CENTRE as a FRACTION of monitor \(monitor), 0...1, top-left; "
                + "pt is the element size in points. Copy c straight into computer_move_to — the "
                + "digits are fractions, not pixels — or name the element in "
                + "computer_target_ax_action as role:name. \"twist\" is a disclosure chevron: it "
                + "toggles a folder and is the smallest target on screen. [brackets] list the AX "
                + "actions the element declares; \"disabled\" means it is greyed out and ignores "
                + "them; [?] means the actions could not be read. When several lines share a "
                + "role and a name, append #2, #3… in this order to pick one."
        ]
        for (index, element) in elements.enumerated() {
            lines.append(line(for: element, index: index))
        }
        return lines.joined(separator: "\n")
    }

    /// One directory line. Shared with the action tool, so a candidate it echoes back looks exactly
    /// like the line the model was reading.
    static func line(for element: AXElementInfo, index: Int) -> String {
        let name = AXText.oneLine(element.name, limit: 42)
        let paddedName = name.count < 30
            ? name + String(repeating: " ", count: 30 - name.count)
            : name + " "
        let size = String(format: "%.0fx%.0fpt", element.sizePoints.width, element.sizePoints.height)
        var line = " [\(index + 1)] \(element.role.padding(toLength: 7, withPad: " ", startingAt: 0))"
        line += "\"\(paddedName)\" c="
        line += "\(MonitorMapping.format(element.center.x)),\(MonitorMapping.format(element.center.y))"
        line += " \(size)"
        if !element.note.isEmpty { line += "  \(element.note)" }
        line += " " + element.actionHint
        return line
    }
}
