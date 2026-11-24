// ComputerUseAXRead.swift
// ChappieCore
//
// WHY THIS FILE:
// Thin, synchronous wrappers over the accessibility C API. Every call here is a cross-process
// round trip to the target app, so none of this may run on the main thread: callers go through a
// detached task (see ComputerUseAXWalker). Kept apart from the walk and the formatting so each of
// those stays readable and the only code that touches AXUIElement directly is in one place.

import Foundation
import CoreGraphics
import ApplicationServices

enum AXRead {

    /// Longest a single attribute or action call may block on an unresponsive app.
    static let messagingTimeout: Float = 4

    static func limitMessaging(of app: AXUIElement) {
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
    }

    static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement]? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? [AXUIElement]
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// A scalar attribute as text. AXValue is a CFNumber on a disclosure triangle and a CFString
    /// almost everywhere else, so reading it as text alone silently loses the chevron's state.
    static func scalar(_ element: AXUIElement, _ name: String) -> String? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
              let raw else { return nil }
        if let text = raw as? String { return text.isEmpty ? nil : text }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }

    /// "expanded" / "collapsed" for a chevron, or nil when the element does not say.
    /// The value comes first because it is the attribute Xcode's outline actually exposes: the live
    /// log read `value=0 → value=1` off it. AXExpanded is only the fallback for apps that have no
    /// numeric value, so a spurious flag on those cannot flip a state the value already gave.
    static func expansion(_ element: AXUIElement) -> String? {
        expansionNote(expanded: nil, value: scalar(element, kAXValueAttribute))
            ?? expansionNote(expanded: bool(element, "AXExpanded"), value: nil)
    }

    /// The rule behind `expansion(_:)`, pure so it can be tested without a live element.
    static func expansionNote(expanded flag: Bool?, value: String?) -> String? {
        switch value {
        case "1", "true": return "expanded"
        case "0", "false": return "collapsed"
        default: break
        }
        guard let flag else { return nil }
        return flag ? "expanded" : "collapsed"
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    /// Frame in points (top-left origin, spans all monitors), or nil for a missing or empty one.
    static func frame(_ element: AXUIElement) -> CGRect? {
        var rawPosition: AnyObject?
        var rawSize: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &rawPosition) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &rawSize) == .success,
              let rawPosition, let rawSize,
              CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &origin),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Actions the element DECLARES. A declared action is not a guarantee that it does anything.
    static func actionNames(_ element: AXUIElement) -> [String]? {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return nil }
        return names as? [String] ?? []
    }

    /// The part of an element's state that a press typically changes, as one comparable string:
    /// a chevron's value, an expanded flag, a row's selection.
    static func stateSummary(_ element: AXUIElement) -> String {
        var parts: [String] = []
        var raw: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success,
           let raw {
            if let text = raw as? String, text.count <= 60 {
                parts.append("value=\(text)")
            } else if let number = raw as? NSNumber {
                parts.append("value=\(number)")
            }
        }
        if let expanded = bool(element, "AXExpanded") { parts.append("expanded=\(expanded)") }
        if let selected = bool(element, kAXSelectedAttribute) { parts.append("selected=\(selected)") }
        if let enabled = bool(element, kAXEnabledAttribute) { parts.append("enabled=\(enabled)") }
        return parts.isEmpty ? "no readable state" : parts.joined(separator: " ")
    }

    /// True when `ancestor` is `element` itself or one of its parents, within a few levels.
    static func isSameOrAncestor(_ ancestor: AXUIElement, of element: AXUIElement, levels: Int = 8) -> Bool {
        var current: AXUIElement? = element
        for _ in 0...levels {
            guard let node = current else { return false }
            if CFEqual(node, ancestor) { return true }
            current = Self.element(node, kAXParentAttribute)
        }
        return false
    }
}
