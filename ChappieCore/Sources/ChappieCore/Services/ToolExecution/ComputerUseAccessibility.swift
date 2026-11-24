// ComputerUseAccessibility.swift
// ChappieCore
//
// WHY THIS FILE:
// The overview frame is capped at 1440 px, so a 10 pt disclosure chevron is about two pixels wide:
// its shape is readable, its position is not. The accessibility tree answers exactly that question —
// every control already carries its exact frame — so this file turns it into a compact directory of
// one line per target, each with the geometric CENTRE as a fraction of the monitor, ready to paste
// straight into computer_move_to. Nothing is drawn on the picture: the directory is a reference that
// rides beside the frame in the same tool result, so the model reads the screen by eye and aims by
// numbers.
//
// The AX tree is mostly containers (windows, scroll areas, split groups, cells). Only the leaves a
// human would actually click survive the whitelist below. Outline rows get special treatment: Xcode
// and the Finder put the row's NAME in a text field and the disclosure chevron in its own
// AXDisclosureTriangle, each with its own frame, so a row yields both a "twist" and a "row" target.

import Foundation
import CoreGraphics
import AppKit
import ApplicationServices

/// One aimable control, already reduced to the two numbers the model needs.
struct AXElementInfo: Equatable {
    /// "twist" for a disclosure chevron, otherwise the short role name of the control.
    let role: String
    /// Visible label: the row's file name, the button's title, the field's current value.
    let name: String
    /// Geometric centre, as a fraction of the monitor (0...1 on each axis, top-left origin).
    let center: CGPoint
    /// Size in points — tells the model whether it is aiming at a chevron or a whole row.
    let sizePoints: CGSize
    /// "expanded" / "collapsed" for chevrons, the item kind for rows, empty otherwise.
    let note: String
}

extension ToolExecutionService {

    // MARK: - Public entry point

    /// Reads the accessibility tree of the app under the cursor and formats it as a directory.
    /// Returns the text block only; the caller attaches the frame.
    @MainActor
    static func axDirectory(monitor: Int, limit: Int) -> String {
        guard isAccessibilityTrusted() else {
            return "AX directory: Accessibility permission is not granted, so no elements are "
                + "available. Grant it in System Settings → Privacy & Security → Accessibility. "
                + "Aim by eye from the frame, or use computer_zoom."
        }
        guard let mapping = monitorMapping(monitor: monitor) else {
            return "AX directory: monitor \(monitor) not found."
        }
        let bounds = mapping.displayBounds
        let cursor = currentCursorPosition()
        guard let pid = appUnderCursor(at: cursor) else {
            return "AX directory: no application window under the cursor. Move the cursor over the "
                + "target window, then call this tool again."
        }
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        let collected = collect(pid: pid, displayBounds: bounds, limit: limit)
        return AXElementInfo.format(
            collected.shown,
            appName: appName,
            monitor: monitor,
            omitted: collected.total - collected.shown.count
        )
    }

    // MARK: - App under the cursor

    /// Same rule the click uses to decide which app to activate: whatever owns the content at the
    /// point, falling back to the frontmost application.
    ///
    /// The window list alone cannot answer this. The Dock owns a screen-sized window above every
    /// application window, so "topmost window containing the point" reports "Dock" for arbitrary
    /// points. Accessibility hit-testing asks for the element that is really there, so it goes
    /// first; the window list is only the fallback for when AX is unavailable.
    @MainActor
    static func appUnderCursor(at point: CGPoint) -> pid_t? {
        if let pid = accessibilityPID(at: point) { return pid }
        if let pid = windowListPID(at: point) { return pid }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// pid the accessibility framework reports for the element at the point.
    @MainActor
    private static func accessibilityPID(at point: CGPoint) -> pid_t? {
        guard isAccessibilityTrusted() else { return nil }
        var element: AXUIElement?
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementCopyElementAtPosition(
            system, Float(point.x), Float(point.y), &element
        ) == .success, let element else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        // The Dock is not a real hit here: its transparent backdrop still answers for points that
        // belong to another app. Its own icons are reachable through the window-list fallback.
        guard !isDock(pid) else { return nil }
        return pid
    }

    /// pid of the topmost ordinary window containing the point. Only layer 0 holds real
    /// application windows; the Dock, the menu bar and Stage Manager sit above it.
    @MainActor
    private static func windowListPID(at point: CGPoint) -> pid_t? {
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[CFString: Any]] ?? []
        for info in windows {
            guard let layer = info[kCGWindowLayer] as? Int, layer == 0 else { continue }
            guard let pid = info[kCGWindowOwnerPID] as? pid_t,
                  let box = info[kCGWindowBounds] as? [String: CGFloat],
                  let x = box["X"], let y = box["Y"],
                  let w = box["Width"], let h = box["Height"] else { continue }
            if CGRect(x: x, y: y, width: w, height: h).contains(point) { return pid }
        }
        return nil
    }

    @MainActor
    private static func isDock(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.dock"
    }

    // MARK: - Tree walk

    private static func collect(
        pid: pid_t,
        displayBounds: CGRect,
        limit: Int
    ) -> (shown: [AXElementInfo], total: Int) {
        let app = AXUIElementCreateApplication(pid)
        let window = axElement(app, kAXFocusedWindowAttribute)
            ?? (axAttributes(app, kAXWindowsAttribute)?.first)
        var found: [AXElementInfo] = []
        var budget = 4000
        visit(window ?? app, displayBounds: displayBounds, depth: 0, budget: &budget, into: &found)

        // Reading order: top to bottom, then left to right. A directory the eye can follow.
        let ordered = found.sorted {
            abs($0.center.y - $1.center.y) > 0.002 ? $0.center.y < $1.center.y
                                                   : $0.center.x < $1.center.x
        }
        return (Array(ordered.prefix(limit)), ordered.count)
    }

    private static func visit(
        _ element: AXUIElement,
        displayBounds: CGRect,
        depth: Int,
        budget: inout Int,
        into found: inout [AXElementInfo]
    ) {
        guard depth <= 30, budget > 0 else { return }
        budget -= 1
        let role = axString(element, kAXRoleAttribute) ?? ""

        // An outline owns its rows: their labels and chevrons live in the row cells, and walking the
        // outline generically would emit the same cells as anonymous noise.
        if role == kAXOutlineRole {
            appendOutlineRows(element, displayBounds: displayBounds, into: &found)
            return
        }
        if let info = elementInfo(element, role: role, displayBounds: displayBounds) {
            found.append(info)
        }
        for child in axAttributes(element, kAXChildrenAttribute) ?? [] {
            visit(child, displayBounds: displayBounds, depth: depth + 1, budget: &budget, into: &found)
        }
    }

    private static func appendOutlineRows(
        _ outline: AXUIElement,
        displayBounds: CGRect,
        into found: inout [AXElementInfo]
    ) {
        let rows = axAttributes(outline, kAXRowsAttribute) ?? []
        for row in rows.prefix(300) {
            var name = ""
            var kind = ""
            var twist: (center: CGPoint, size: CGSize, expanded: String)?
            scanRow(row, depth: 0) { element, role in
                switch role {
                case kAXTextFieldRole, kAXStaticTextRole:
                    if name.isEmpty { name = axString(element, kAXValueAttribute) ?? "" }
                case kAXImageRole:
                    if kind.isEmpty { kind = axString(element, kAXTitleAttribute) ?? "" }
                case "AXDisclosureTriangle":
                    if twist == nil, let box = frame(element),
                       let center = clippedCenter(box, displayBounds) {
                        let state = axString(element, kAXValueAttribute) ?? ""
                        twist = (center, box.size, state == "1" ? "expanded" : "collapsed")
                    }
                default: break
                }
            }
            guard !name.isEmpty, let box = frame(row),
                  let rowCenter = clippedCenter(box, displayBounds) else { continue }
            // The chevron sits at the row's left edge; it is the smallest target on screen.
            if let twist {
                found.append(AXElementInfo(role: "twist", name: name, center: twist.center,
                                           sizePoints: twist.size, note: twist.expanded))
            }
            found.append(AXElementInfo(role: "row", name: name, center: rowCenter,
                                       sizePoints: box.size, note: kind.lowercased()))
        }
    }

    /// Depth-limited descent that reports (element, role) pairs without collecting the tree.
    private static func scanRow(
        _ element: AXUIElement,
        depth: Int,
        visit: (AXUIElement, String) -> Void
    ) {
        guard depth <= 5 else { return }
        let role = axString(element, kAXRoleAttribute) ?? ""
        visit(element, role)
        for child in axAttributes(element, kAXChildrenAttribute) ?? [] {
            scanRow(child, depth: depth + 1, visit: visit)
        }
    }

    // MARK: - Single element → aim line

    private static func elementInfo(
        _ element: AXUIElement,
        role: String,
        displayBounds: CGRect
    ) -> AXElementInfo? {
        let name = axString(element, kAXTitleAttribute)
            ?? axString(element, kAXValueAttribute)
            ?? axString(element, "AXDescription")
            ?? ""
        guard !name.isEmpty else { return nil }
        let isTwist = role == "AXDisclosureTriangle"
        guard isTwist || AXElementInfo.targetRoles.contains(role) else { return nil }
        guard let box = frame(element), let center = clippedCenter(box, displayBounds) else {
            return nil
        }
        var note = ""
        if isTwist {
            note = (axString(element, kAXValueAttribute) ?? "") == "1" ? "expanded" : "collapsed"
        }
        return AXElementInfo(role: isTwist ? "twist" : AXElementInfo.shortRole(role),
                             name: name, center: center, sizePoints: box.size, note: note)
    }

    // MARK: - AX attribute helpers

    private static func axAttributes(_ element: AXUIElement, _ name: String) -> [AXUIElement]? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? [AXUIElement]
    }

    private static func axElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func axString(_ element: AXUIElement, _ name: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let raw = axRawValue(element, kAXPositionAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        guard AXValueGetValue(raw as! AXValue, .cgPoint, &origin) else { return nil }

        guard let rawSize = axRawValue(element, kAXSizeAttribute),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(rawSize as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func axRawValue(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else {
            return nil
        }
        return raw
    }

    /// Centre of a frame as a monitor fraction, or nil when the element is off this monitor.
    private static func clippedCenter(_ box: CGRect, _ bounds: CGRect) -> CGPoint? {
        let center = CGPoint(x: box.midX, y: box.midY)
        guard bounds.contains(center) else { return nil }
        return CGPoint(
            x: MonitorMapping.unit((center.x - bounds.minX) / max(bounds.width, 1)),
            y: MonitorMapping.unit((center.y - bounds.minY) / max(bounds.height, 1))
        )
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
        case "AXLink":                                                return "link"
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
                + "digits are fractions, not pixels. \"twist\" is a disclosure chevron: it toggles a "
                + "folder, and it is the smallest target on screen."
        ]
        for (index, element) in elements.enumerated() {
            var name = element.name.replacingOccurrences(of: "\n", with: " ")
            if name.count > 42 { name = String(name.prefix(41)) + "…" }
            let paddedName = name.count < 30
                ? name + String(repeating: " ", count: 30 - name.count)
                : name + " "
            let size = String(format: "%.0fx%.0fpt", element.sizePoints.width, element.sizePoints.height)
            var line = " [\(index + 1)] \(element.role.padding(toLength: 7, withPad: " ", startingAt: 0))"
            line += "\"\(paddedName)\" c="
            line += "\(MonitorMapping.format(element.center.x)),\(MonitorMapping.format(element.center.y))"
            line += " \(size)"
            if !element.note.isEmpty { line += "  \(element.note)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
