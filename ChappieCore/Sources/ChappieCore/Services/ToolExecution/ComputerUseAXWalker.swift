// ComputerUseAXWalker.swift
// ChappieCore
//
// WHY THIS FILE:
// Walks the accessibility tree of one application and turns it into a directory the model can act
// on. Two rules shape it:
//
//   ONLY WHAT IS ON SCREEN. Every child is visited with a clip rectangle accumulated from its
//   parents — the focused window cut to the display, narrowed further by every scroll area — and an
//   element outside its clip is dropped. Apps that keep far-off rows in the tree (Chromium keeps the
//   whole DOM) therefore cannot feed the model targets it can never hit, and the count of what was
//   dropped is printed so the model knows the list is filtered, not complete.
//
//   ACTIONS UP FRONT. Each surviving element also declares which AX actions it supports, read once
//   per element. This is a cross-process call per element, so the whole walk runs OFF the main actor
//   under a three-minute deadline: past it the walk stops and the directory is marked partial.
//
// The arithmetic lives in ComputerUseAXTarget.swift and the formatting in ComputerUseAccessibility
// .swift; this file only reads and assembles.

import Foundation
import CoreGraphics
import AppKit
import ApplicationServices

extension ToolExecutionService {

    /// What one walk produced. `ordered` is the full list in reading order; the model sees a prefix.
    struct AXSnapshot: @unchecked Sendable {
        let appName: String
        let pid: pid_t
        let displayBounds: CGRect
        let ordered: [AXElementInfo]
        /// Elements the tree had but the screen does not: scrolled away, collapsed, off-window.
        let offscreen: Int
        /// True when the deadline cut the walk short, so the list may be missing controls.
        let partial: Bool
    }

    // MARK: - Entry point

    /// A walk that could not start, carrying the sentence the model should read.
    struct AXWalkError: Error { let message: String }

    /// Walks the app under the cursor. Errors come back as the sentence the model should read.
    @MainActor
    static func axSnapshot(monitor: Int, limit: Int) async -> Result<AXSnapshot, AXWalkError> {
        guard isAccessibilityTrusted() else {
            return .failure(AXWalkError(message:
                "AX directory: Accessibility permission is not granted, so no elements are "
                + "available. Grant it in System Settings → Privacy & Security → Accessibility. "
                + "Aim by eye from the frame, or use computer_zoom."))
        }
        guard let mapping = monitorMapping(monitor: monitor) else {
            return .failure(AXWalkError(message: "AX directory: monitor \(monitor) not found."))
        }
        let displayBounds = mapping.displayBounds
        guard let pid = appUnderCursor(at: currentCursorPosition()) else {
            return .failure(AXWalkError(message:
                "AX directory: no application window under the cursor. Move the cursor "
                + "over the target window, then call this tool again."))
        }
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"

        // AX is a cross-process conversation: reading 120 elements means 120 round trips. Off the
        // main actor, or the whole UI stops answering while the walk runs.
        let walk = await Task.detached(priority: .userInitiated) {
            Self.walk(pid: pid, displayBounds: displayBounds)
        }.value

        var elements = walk.elements
        for index in elements.indices { elements[index].id = index + 1 }
        return .success(AXSnapshot(appName: appName, pid: pid, displayBounds: displayBounds,
                                   ordered: elements, offscreen: walk.offscreen,
                                   partial: walk.partial))
    }

    /// The directory text for a snapshot, limited to what the model should see.
    static func directoryText(_ snapshot: AXSnapshot, monitor: Int, limit: Int) -> String {
        let shown = Array(snapshot.ordered.prefix(limit))
        var omitted = snapshot.ordered.count - shown.count
        if snapshot.partial { omitted += 1 }          // "there is more" is the honest statement here
        let text = AXElementInfo.format(shown, appName: snapshot.appName,
                                        monitor: monitor, omitted: omitted)
        guard snapshot.offscreen > 0 || snapshot.partial else { return text }
        var note = ""
        if snapshot.offscreen > 0 {
            note += "\n\(snapshot.offscreen) more element(s) are in the tree but not on screen "
                + "(scrolled away, collapsed, or outside the window) and were dropped."
        }
        if snapshot.partial {
            note += "\nThe walk hit its 3-minute deadline: the list may be missing controls."
        }
        return text + note
    }

    /// Builds the directory and hands back the snapshot it came from, so a caller that wants to act
    /// on an element does not walk the tree twice without need.
    @MainActor
    static func axDirectory(monitor: Int, limit: Int) async -> String {
        switch await axSnapshot(monitor: monitor, limit: limit) {
        case .failure(let error): return error.message
        case .success(let snapshot): return directoryText(snapshot, monitor: monitor, limit: limit)
        }
    }

    // MARK: - The walk

    private struct WalkResult: @unchecked Sendable {
        let elements: [AXElementInfo]
        let offscreen: Int
        let partial: Bool
    }

    private static func walk(pid: pid_t, displayBounds: CGRect) -> WalkResult {
        let app = AXUIElementCreateApplication(pid)
        AXRead.limitMessaging(of: app)
        let window = AXRead.element(app, kAXFocusedWindowAttribute)
            ?? AXRead.elements(app, kAXWindowsAttribute)?.first
        let windowBox = window.flatMap { AXRead.frame($0) }
        let clip = AXVisibility.visibleArea(window: windowBox, display: displayBounds)

        let collector = AXCollector(display: displayBounds,
                                    deadline: Date().addingTimeInterval(180))
        var budget = 4000
        collector.visit(window ?? app, clip: clip, depth: 0, budget: &budget)

        // Reading order: top to bottom, then left to right. A directory the eye can follow.
        let ordered = collector.found.sorted {
            abs($0.center.y - $1.center.y) > 0.002 ? $0.center.y < $1.center.y
                                                   : $0.center.x < $1.center.x
        }
        return WalkResult(elements: ordered, offscreen: collector.offscreen,
                          partial: collector.partial)
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
}

// MARK: - Collector

/// One mutable walk. A class so the recursion can carry state without inout chains through
/// every level; it never leaves the thread that created it.
private final class AXCollector {

    let display: CGRect
    let deadline: Date
    var found: [AXElementInfo] = []
    var offscreen = 0
    var partial = false

    init(display: CGRect, deadline: Date) {
        self.display = display
        self.deadline = deadline
    }

    func visit(_ element: AXUIElement, clip: CGRect, depth: Int, budget: inout Int) {
        guard depth <= 30, budget > 0 else { return }
        budget -= 1
        if Date() > deadline { partial = true; return }

        let role = AXRead.string(element, kAXRoleAttribute) ?? ""

        // An outline owns its rows: their labels and chevrons live in the row cells, and walking the
        // outline generically would emit the same cells as anonymous noise.
        if role == kAXOutlineRole {
            appendOutlineRows(element, clip: clip)
            return
        }

        var childClip = clip
        // A scroll area hides everything outside its own box; the tree still lists those children.
        if role == kAXScrollAreaRole, let box = AXRead.frame(element) {
            childClip = AXVisibility.narrow(clip, to: box)
        }

        append(element, role: role, clip: childClip)
        for child in AXRead.elements(element, kAXChildrenAttribute) ?? [] {
            visit(child, clip: childClip, depth: depth + 1, budget: &budget)
        }
    }

    // MARK: Rows

    func appendOutlineRows(_ outline: AXUIElement, clip: CGRect) {
        var outlineClip = clip
        if let box = AXRead.frame(outline) { outlineClip = AXVisibility.narrow(clip, to: box) }

        for row in (AXRead.elements(outline, kAXRowsAttribute) ?? []).prefix(300) {
            var name = ""
            var kind = ""
            var twist: (element: AXUIElement, point: CGPoint, size: CGSize, state: String)?
            scanRow(row, depth: 0) { element, role in
                switch role {
                case kAXTextFieldRole, kAXStaticTextRole:
                    if name.isEmpty { name = AXRead.string(element, kAXValueAttribute) ?? "" }
                case kAXImageRole:
                    if kind.isEmpty { kind = AXRead.string(element, kAXTitleAttribute) ?? "" }
                case "AXDisclosureTriangle":
                    if twist == nil, let box = AXRead.frame(element) {
                        let state = AXRead.string(element, kAXValueAttribute) ?? ""
                        twist = (element, AXElementInfo.aimPoint(in: box, role: "twist"),
                                 box.size, state == "1" ? "expanded" : "collapsed")
                    }
                default: break
                }
            }
            guard !name.isEmpty, let box = AXRead.frame(row) else { continue }
            let rowPoint = AXElementInfo.aimPoint(in: box, role: "row")
            let rowCenter = AXVisibility.fraction(of: rowPoint, clip: outlineClip, display: display)
            guard rowCenter != nil else { offscreen += 1; continue }

            // The chevron sits at the row's leading edge; it is the smallest target on screen.
            if let twist {
                if let fraction = AXVisibility.fraction(of: twist.point, clip: outlineClip, display: display) {
                    var info = AXElementInfo(role: "twist", name: name, center: fraction,
                                             sizePoints: twist.size, note: twist.state)
                    info.element = twist.element
                    probeActions(&info)
                    found.append(info)
                } else {
                    offscreen += 1
                }
            }
            var rowInfo = AXElementInfo(role: "row", name: name, center: rowCenter!,
                                        sizePoints: box.size, note: kind.lowercased())
            rowInfo.element = row
            probeActions(&rowInfo)
            found.append(rowInfo)
        }
    }

    /// Depth-limited descent that reports (element, role) pairs without collecting the tree.
    private func scanRow(_ element: AXUIElement, depth: Int, visit: (AXUIElement, String) -> Void) {
        guard depth <= 5 else { return }
        let role = AXRead.string(element, kAXRoleAttribute) ?? ""
        visit(element, role)
        for child in AXRead.elements(element, kAXChildrenAttribute) ?? [] {
            scanRow(child, depth: depth + 1, visit: visit)
        }
    }

    // MARK: Leaves

    private func append(_ element: AXUIElement, role: String, clip: CGRect) {
        let name = AXRead.string(element, kAXTitleAttribute)
            ?? AXRead.string(element, kAXValueAttribute)
            ?? AXRead.string(element, "AXDescription")
            ?? ""
        guard !name.isEmpty else { return }
        let isTwist = role == "AXDisclosureTriangle"
        guard isTwist || AXElementInfo.targetRoles.contains(role) else { return }
        guard let box = AXRead.frame(element) else { return }
        let short = isTwist ? "twist" : AXElementInfo.shortRole(role)
        let point = AXElementInfo.aimPoint(in: box, role: short)
        guard let fraction = AXVisibility.fraction(of: point, clip: clip, display: display) else {
            offscreen += 1
            return
        }
        var note = ""
        if isTwist {
            note = (AXRead.string(element, kAXValueAttribute) ?? "") == "1" ? "expanded" : "collapsed"
        }
        var info = AXElementInfo(role: short, name: name, center: fraction,
                                 sizePoints: box.size, note: note)
        info.element = element
        probeActions(&info)
        found.append(info)
    }

    // MARK: Actions

    /// One cross-process call per element, so it is skipped when the walk is already late.
    private func probeActions(_ info: inout AXElementInfo) {
        guard !partial else { info.actions = nil; return }
        guard Date() < deadline else { partial = true; info.actions = nil; return }
        guard let element = info.element else { info.actions = nil; return }
        info.enabled = AXRead.bool(element, kAXEnabledAttribute) ?? true
        // A greyed-out control declares the same actions and ignores all of them: do not spend a
        // call asking, and never let the model press it.
        guard info.enabled else { info.actions = nil; return }
        info.actions = AXRead.actionNames(element)
    }
}
