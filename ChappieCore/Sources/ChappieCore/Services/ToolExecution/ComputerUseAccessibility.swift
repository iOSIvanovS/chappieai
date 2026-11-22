// ComputerUseAccessibility.swift
// ChappieCore
//
// WHY THIS FILE:
// Reading the accessibility tree turns "guess a pixel from a downscaled picture" into "click the
// centre of the control macOS itself reports". A 12x12 window button can never be hit reliably
// from a screenshot, but its AXFrame is exact.
//
// COORDINATE SPACE:
// AX frames are measured from the top-left corner of the primary display — the same space CGEvent
// posts into. A frame's centre is therefore usable as a click point without any conversion.
//
// WHY THE TARGET APP IS FOUND THROUGH THE WINDOW LIST:
// Chappie takes focus back after every answer, so "frontmost app" would always be Chappie. The
// topmost normal window that is not ours is the app the user is actually working in.

import Foundation
import ApplicationServices
import CoreGraphics
import AppKit

// MARK: - Element

/// One clickable thing the accessibility tree reported, reduced to what a click needs.
public struct AccessibleElement: Equatable, Sendable {
    /// Longest title kept. An AXTextArea reports its ENTIRE document as the value attribute, and
    /// that value is what reaches the prompt: one open 6000-line markdown file cost about 8000
    /// tokens per screenshot. Truncated at the type boundary so no caller can reintroduce it.
    public static let maxTitleLength = 60

    public let role: String
    public let title: String
    /// AX frame, top-left origin of the primary display, points.
    public let frame: CGRect

    public init(role: String, title: String, frame: CGRect) {
        self.role = role
        self.title = Self.normalized(title)
        self.frame = frame
    }

    /// Collapses line breaks and runs of whitespace into single spaces, then cuts to maxTitleLength.
    /// A control name is one line by definition; the line breaks only ever come from document text.
    static func normalized(_ raw: String) -> String {
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > maxTitleLength else { return collapsed }
        return String(collapsed.prefix(maxTitleLength)) + "…"
    }

    public var center: CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }

    /// The line the model reads in the element list.
    public var summary: String {
        let name = title.isEmpty ? "(untitled)" : title
        return "\(role) \"\(name)\" at (\(Int(center.x.rounded())), \(Int(center.y.rounded())))"
    }
}

// MARK: - Window

/// A window from the on-screen window list, in CG coordinates.
public struct WindowInfo: Equatable, Sendable {
    public let pid: pid_t
    public let layer: Int
    public let bounds: CGRect

    public init(pid: pid_t, layer: Int, bounds: CGRect) {
        self.pid = pid
        self.layer = layer
        self.bounds = bounds
    }
}

// MARK: - Roles

public enum AccessibilityRoles {
    /// Controls a user can act on. Containers (AXWindow, AXGroup, AXScrollArea) are deliberately
    /// absent: their frames cover everything and would swallow the targets inside them.
    public static let interactive: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXSearchField",
        "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXMenuButton",
        "AXMenuItem", "AXMenuBarItem", "AXSlider", "AXIncrementor",
        "AXDisclosureTriangle", "AXCell", "AXHandle"
    ]
    // AXRow and AXValueIndicator are absent on purpose: a row is a container whose cell sits at the
    // same centre (clicking the cell selects the row just the same), and a value indicator is a
    // scrollbar thumb. Both only added untitled lines to the list.
}

// MARK: - Selection

/// Pure narrowing of a raw accessibility dump into a list short enough to show the model.
public enum AccessibilitySelection {
    /// More than a person would ever scan in one look; the cap keeps the prompt small.
    public static let defaultLimit = 80
    /// Below this a control is a hairline separator or an invisible hit area.
    public static let minSide: CGFloat = 4
    /// A control covering this share of the window in both directions is a container.
    public static let containerRatio: CGFloat = 0.9

    public static func select(_ elements: [AccessibleElement],
                              windowBounds: CGRect? = nil,
                              limit: Int = defaultLimit) -> [AccessibleElement] {
        var seen = Set<String>()
        var kept: [AccessibleElement] = []

        for element in elements {
            let frame = element.frame
            guard frame.width >= minSide, frame.height >= minSide else { continue }

            if let windowBounds, windowBounds.width > 0, windowBounds.height > 0 {
                if frame.width >= windowBounds.width * containerRatio,
                   frame.height >= windowBounds.height * containerRatio {
                    continue
                }
                // A control reaching outside the window is a scrolling document, not a target: its
                // centre sits off-screen, so its number would promise a click somewhere else. This
                // is what removed the 6611pt-tall editor text area from an otherwise good list.
                guard windowBounds.contains(element.center) else { continue }
            }

            // The same control often appears twice in the tree (button and its cell).
            // Rounded to whole points so sub-pixel drift does not defeat the check.
            let key = "\(element.role)|\(element.title)|\(Int(frame.minX.rounded()))|"
                + "\(Int(frame.minY.rounded()))|\(Int(frame.width.rounded()))|\(Int(frame.height.rounded()))"
            guard seen.insert(key).inserted else { continue }

            kept.append(element)
        }

        // Reading order: top to bottom, and left to right within the same visual row.
        kept.sort { a, b in
            if abs(a.frame.minY - b.frame.minY) > 8 { return a.frame.minY < b.frame.minY }
            return a.frame.minX < b.frame.minX
        }
        return Array(kept.prefix(limit))
    }
}

// MARK: - Reader

public enum AccessibilityReader {

    /// The topmost normal window that belongs to someone else — the app the user is working in.
    /// - Parameter within: only windows overlapping this area qualify (one display of several).
    public static func targetWindow(excluding ownPid: pid_t,
                                    within area: CGRect? = nil,
                                    minSide: CGFloat = 60) -> WindowInfo? {
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                             kCGNullWindowID) as? [[CFString: Any]] ?? []
        let windows: [WindowInfo] = raw.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID] as? pid_t,
                  let layer = info[kCGWindowLayer] as? Int,
                  let bounds = info[kCGWindowBounds] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"] else { return nil }
            return WindowInfo(pid: pid, layer: layer, bounds: CGRect(x: x, y: y, width: w, height: h))
        }
        return pickTarget(from: windows, excluding: ownPid, within: area, minSide: minSide)
    }

    /// Split out from the window list so the rule can be tested without a live window server.
    public static func pickTarget(from windows: [WindowInfo],
                                  excluding ownPid: pid_t,
                                  within area: CGRect? = nil,
                                  minSide: CGFloat = 60) -> WindowInfo? {
        windows.first { window in
            window.pid != ownPid
                && window.layer == 0                  // 0 = normal window, not a panel or a bar
                && window.bounds.width >= minSide
                && window.bounds.height >= minSide
                && (area.map { $0.intersects(window.bounds) } ?? true)
        }
    }

    /// Interactive elements of one window of an app, in reading order.
    /// - Parameter matching: bounds from the window list. When given, the AX window that covers them
    ///   best is used — an app's focused window can be a sheet or a panel while the window the user
    ///   sees on top is another one, and numbering the wrong window would produce a confident list
    ///   pointing at controls that are not on the picture.
    public static func elements(of pid: pid_t, matching bounds: CGRect? = nil) -> [AccessibleElement] {
        guard AXIsProcessTrusted() else { return [] }
        let application = AXUIElementCreateApplication(pid)
        guard let window = window(of: application, matching: bounds) else { return [] }

        var collected: [AccessibleElement] = []
        walk(window, depth: 0, into: &collected)

        let bounds = windowFrame(of: window)
        return AccessibilitySelection.select(collected, windowBounds: bounds)
    }

    /// The AX window covering `bounds` best, or the app's own focused window when there is nothing
    /// to match against.
    private static func window(of application: AXUIElement, matching bounds: CGRect?) -> AXUIElement? {
        guard let bounds,
              let windows = copy(application, kAXWindowsAttribute) as? [AXUIElement],
              !windows.isEmpty else {
            return focusedWindow(of: application)
        }
        let scored: [(window: AXUIElement, shared: CGFloat)] = windows.compactMap { window in
            guard let frame = frame(of: window) else { return nil }
            let shared = frame.intersection(bounds)
            guard !shared.isNull, shared.width > 0, shared.height > 0 else { return nil }
            return (window, shared.width * shared.height)
        }
        return scored.max { $0.shared < $1.shared }?.window ?? focusedWindow(of: application)
    }

    // MARK: Tree walking

    private static let maxDepth = 40
    private static let maxNodes = 4000

    private static func walk(_ element: AXUIElement, depth: Int, into out: inout [AccessibleElement]) {
        guard depth < maxDepth, out.count < maxNodes else { return }

        let role = string(element, kAXRoleAttribute) ?? ""
        if AccessibilityRoles.interactive.contains(role), let frame = frame(of: element) {
            // Falls back through description and value: an icon-only button often has no title.
            let title = string(element, kAXTitleAttribute)
                ?? string(element, kAXDescriptionAttribute)
                ?? string(element, kAXValueAttribute)
                ?? ""
            out.append(AccessibleElement(role: role, title: title, frame: frame))
        }

        for child in children(of: element) {
            walk(child, depth: depth + 1, into: &out)
        }
    }

    private static func focusedWindow(of application: AXUIElement) -> AXUIElement? {
        if let window = element(application, kAXFocusedWindowAttribute) { return window }
        if let window = element(application, kAXMainWindowAttribute) { return window }
        if let windows = copy(application, kAXWindowsAttribute) as? [AXUIElement] {
            return windows.first
        }
        return nil
    }

    private static func windowFrame(of window: AXUIElement) -> CGRect? {
        frame(of: window)
    }

    // MARK: Attribute access

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }
        let text = value as! String
        return text.isEmpty ? nil : text
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        copy(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = copy(element, kAXPositionAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = copy(element, kAXSizeAttribute),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
