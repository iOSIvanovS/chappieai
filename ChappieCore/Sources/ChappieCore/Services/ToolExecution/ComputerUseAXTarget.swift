// ComputerUseAXTarget.swift
// ChappieCore
//
// WHY THIS FILE:
// The pure half of accessibility targeting: everything that decides WHERE a target is and WHICH
// one the model meant, with no AX calls, so it can be pinned by tests. The directory (what the
// model reads) and computer_target_ax_action (what it fires) must agree on every number, so both
// go through the functions here and nowhere else:
//   - aimPoint      the point to hit inside an element's frame
//   - AXVisibility  what counts as on screen
//   - AXTargetResolver  "role:name#n" -> one element, or a loud refusal
//   - AXActionName  AXPress <-> press

import Foundation
import CoreGraphics

// MARK: - Aim point

extension AXElementInfo {

    /// Roles whose glyph hugs the leading edge of a frame that is wider than the glyph.
    /// Measured on Xcode's outline: the disclosure triangle's frame is 15x24 pt, the triangle is
    /// drawn at its left side, so the geometric centre lands on empty cell background.
    static let leadingGlyphRoles: Set<String> = ["twist", "check", "radio"]

    /// Share of the frame width where the glyph sits, capped in points so a checkbox with a long
    /// label is still hit on the box, not on the middle of the label.
    static let leadingGlyphShare: CGFloat = 0.25
    static let leadingGlyphMaxOffset: CGFloat = 10

    /// The point to hit, in points (CGEvent space). `role` is the short role the directory prints.
    static func aimPoint(in box: CGRect, role: String) -> CGPoint {
        guard leadingGlyphRoles.contains(role) else {
            return CGPoint(x: box.midX, y: box.midY)
        }
        let offset = min(box.width * leadingGlyphShare, leadingGlyphMaxOffset)
        return CGPoint(x: box.minX + offset, y: box.midY)
    }
}

// MARK: - Visibility

enum AXVisibility {

    /// The part of the screen an element may occupy: the focused window cut to the display.
    /// A window hanging over the screen edge contributes only the part that is really visible.
    static func visibleArea(window: CGRect?, display: CGRect) -> CGRect {
        guard let window else { return display }
        return narrow(display, to: window)
    }

    /// `clip` cut to `box`; an empty overlap yields `.zero`, which contains nothing.
    static func narrow(_ clip: CGRect, to box: CGRect) -> CGRect {
        let cut = clip.intersection(box)
        return cut.isNull || cut.isEmpty ? .zero : cut
    }

    /// Monitor fraction of a point, or nil when the point lies outside the clip or the display.
    static func fraction(of point: CGPoint, clip: CGRect, display: CGRect) -> CGPoint? {
        guard clip.contains(point), display.contains(point) else { return nil }
        return CGPoint(
            x: MonitorMapping.unit((point.x - display.minX) / max(display.width, 1)),
            y: MonitorMapping.unit((point.y - display.minY) / max(display.height, 1))
        )
    }
}

// MARK: - Action names

enum AXActionName {

    private static let table: [String: String] = [
        "AXPress": "press", "AXShowMenu": "menu", "AXConfirm": "confirm",
        "AXIncrement": "inc", "AXDecrement": "dec", "AXPick": "pick", "AXCancel": "cancel",
        "AXRaise": "raise", "AXShowAlternateUI": "alt", "AXShowDefaultUI": "default"
    ]

    /// Longest short name the directory prints, ellipsis included.
    static let maxShortLength = 24

    /// The short name the directory prints. An unknown action still yields something readable.
    /// The result is one line and bounded, because Xcode declares actions whose names carry a
    /// debug description with newlines in it — printed raw one element would flood the directory.
    /// Matching runs through the same function, so the name the model copies back always resolves
    /// to the action it was printed from.
    static func short(_ full: String) -> String {
        let cleaned = AXText.oneLine(full, limit: maxShortLength)
        if let known = table[cleaned] { return known }
        let trimmed = cleaned.hasPrefix("AX") ? String(cleaned.dropFirst(2)) : cleaned
        let lowered = trimmed.lowercased()
        return lowered.isEmpty ? "?" : lowered
    }

    /// Short names for display: cleaned, deduplicated in declaration order, and cut with "+N" so a
    /// single noisy element cannot spend a whole paragraph on its action list.
    static func listed(_ actions: [String], limit: Int = 6) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        for action in actions {
            let name = short(action)
            guard seen.insert(name).inserted else { continue }
            unique.append(name)
        }
        guard unique.count > limit else { return unique }
        return Array(unique.prefix(limit)) + ["+\(unique.count - limit)"]
    }

    /// The element's own action that the model's word stands for, or nil. Accepts "press",
    /// "AXPress" and "axpress" alike, so a case slip never turns into a refusal.
    static func match(_ input: String, in actions: [String]) -> String? {
        let wanted = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return nil }
        return actions.first { $0.lowercased() == wanted || short($0) == wanted }
    }
}

// MARK: - Target resolution

enum AXTargetResolution: Equatable {
    /// Index into the element list.
    case found(Int)
    /// Nothing matched; indexes of the nearest candidates by name.
    case notFound([Int])
    /// Several matched; indexes in directory order, for the model to pick with "#n".
    case ambiguous([Int])
    case invalid(String)
}

enum AXTargetResolver {

    struct Spec: Equatable {
        let role: String
        let name: String
        let ordinal: Int?
    }

    /// "twist:ViewModels", "row:Chappie#2". Only the first colon splits, so a name may contain
    /// colons; the optional "#n" suffix is the 1-based pick among equal matches.
    static func parse(_ text: String) -> Spec? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let role = normalizeRole(String(text[..<colon]))
        var name = String(text[text.index(after: colon)...])
        var ordinal: Int?
        if let hash = name.lastIndex(of: "#"),
           let n = Int(name[name.index(after: hash)...].trimmingCharacters(in: .whitespaces)), n >= 1 {
            ordinal = n
            name = String(name[..<hash])
        }
        name = name.trimmingCharacters(in: .whitespaces)
        guard !role.isEmpty, !name.isEmpty else { return nil }
        return Spec(role: role, name: name, ordinal: ordinal)
    }

    static func resolve(_ text: String, in elements: [AXElementInfo]) -> AXTargetResolution {
        guard let spec = parse(text) else {
            return .invalid("target must look like role:name, for example twist:ViewModels or "
                + "row:Chappie#2 (the #2 picks the second of several equal matches)")
        }
        let wanted = normalizeName(spec.name)
        let sameRole = elements.indices.filter { elements[$0].role == spec.role }

        var matches = sameRole.filter { normalizeName(elements[$0].name) == wanted }
        // A partial name is accepted only when nothing matches exactly: "ViewModels" must never
        // quietly become "ViewModelsTests" while a real "ViewModels" exists.
        if matches.isEmpty {
            matches = sameRole.filter { normalizeName(elements[$0].name).contains(wanted) }
        }

        if let ordinal = spec.ordinal {
            guard ordinal <= matches.count else { return .notFound(candidates(wanted, in: elements)) }
            return .found(matches[ordinal - 1])
        }
        switch matches.count {
        case 0:  return .notFound(candidates(wanted, in: elements))
        case 1:  return .found(matches[0])
        default: return .ambiguous(matches)
        }
    }

    // MARK: Helpers

    /// "AXButton" and "button" are the same role; the directory prints the short one.
    static func normalizeRole(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("AX") ? AXElementInfo.shortRole(trimmed) : trimmed.lowercased()
    }

    static func normalizeName(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    /// Up to five elements of ANY role whose name overlaps the query, so a wrong role is visible.
    private static func candidates(_ wanted: String, in elements: [AXElementInfo]) -> [Int] {
        let near = elements.indices.filter {
            let name = normalizeName(elements[$0].name)
            return !name.isEmpty && (name.contains(wanted) || wanted.contains(name))
        }
        return Array(near.prefix(5))
    }
}
