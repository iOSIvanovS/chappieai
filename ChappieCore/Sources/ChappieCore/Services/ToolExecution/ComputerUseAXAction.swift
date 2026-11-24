// ComputerUseAXAction.swift
// ChappieCore
//
// WHY THIS FILE:
// computer_target_ax_action is the trusted path. Eyeballing a coordinate and re-checking it with a
// magnifier costs two extra calls and, worse, invites the model to "correct" a number that was
// exact in the first place. Here the model names an element from the accessibility directory
// ("twist:ViewModels") and the tool finds it, aims at it the same way the directory does, and
// either fires the element's own AX action or clicks its point with a real mouse event.
//
// A DECLARED ACTION IS NOT A PROMISE. AXPress can be listed and do nothing, so every AX action
// compares the element's state before and after and says plainly whether anything changed. When an
// action does nothing, "mouse" falls back to a real click on the element's own point.

import Foundation
import CoreGraphics
import AppKit

extension ToolExecutionService {

    /// Words the model may pass as an action that mean "use the mouse" rather than an AX action.
    private static let mouseActions: Set<String> = ["mouse", "click", "left", "double"]

    func performTargetAXAction(argsData: Data) async -> String {
        struct Args: Decodable {
            var target: String?
            var action: String?
            var monitor: FlexInt?
            var delay: FlexDouble?
            var zoom: FlexDouble?
        }
        let raw = String(data: argsData, encoding: .utf8) ?? "<non-utf8>"
        guard let args = try? JSONDecoder().decode(Args.self, from: argsData),
              let target = args.target?.trimmingCharacters(in: .whitespaces), !target.isEmpty else {
            return "❌ computer_target_ax_action: 'target' is required, written role:name exactly "
                + "as the computer_elements directory prints it — for example twist:ViewModels. "
                + "Raw args: \(raw)"
        }
        let monitor = args.monitor?.value ?? 0
        let delay = args.delay?.value ?? 1.0
        let word = (args.action ?? "press").trimmingCharacters(in: .whitespaces).lowercased()

        // The directory is the tool's only map: walk again, so the element is the one on screen NOW.
        let snapshot: AXSnapshot
        switch await Self.axSnapshot(monitor: monitor, limit: 400) {
        case .failure(let error):
            return "❌ computer_target_ax_action: " + error.message
        case .success(let taken):
            snapshot = taken
        }
        let published = Array(snapshot.ordered.prefix(400))

        let element: AXElementInfo
        switch AXTargetResolver.resolve(target, in: published) {
        case .invalid(let reason):
            return "❌ computer_target_ax_action: " + reason
        case .notFound(let candidates):
            return notFoundMessage(target, appName: snapshot.appName,
                                   candidates: candidates, in: published)
        case .ambiguous(let indexes):
            return ambiguousMessage(target, appName: snapshot.appName,
                                    indexes: indexes, in: published)
        case .found(let index):
            element = published[index]
        }

        guard element.enabled else {
            return "❌ computer_target_ax_action: \(element.reference) is disabled (greyed out). "
                + "It declares actions and ignores them, so nothing was sent. Enable it first, or "
                + "pick another element."
        }
        guard let live = element.element, let box = AXRead.frame(live) else {
            return "❌ computer_target_ax_action: \(element.reference) has no readable frame now. "
                + "Call computer_elements again."
        }
        let label = "\(element.role) \"\(element.name)\""
        let aim = AXElementInfo.aimPoint(in: box, role: element.role)

        if Self.mouseActions.contains(word) {
            // A real click leaves the same kind of trace an AX action does, and only that one, so
            // its state is captured here and compared after — the mouse path used to say nothing.
            let beforeClick = AXRead.stateSummary(live)
            return await clickElement(element, label: label, point: aim, before: beforeClick,
                                      double: word == "double", monitor: monitor,
                                      delay: delay, zoom: args.zoom?.value)
        }

        // Unknown action list (the walk ran out of time): be optimistic with the default action
        // rather than refuse a target the model can see, and let the state check report the truth.
        let chosen: String?
        if let declared = element.actions {
            chosen = AXActionName.match(word, in: declared)
        } else {
            chosen = word == "press" ? kAXPressAction as String : nil
        }
        guard let axAction = chosen else {
            return notAvailableMessage(word: word, label: label, reference: element.reference,
                                       actions: element.actions)
        }

        let before = AXRead.stateSummary(live)
        let error = AXUIElementPerformAction(live, axAction as CFString)
        guard error == .success else {
            return "❌ computer_target_ax_action: \(label) refused \(AXActionName.short(axAction)) "
                + "(AX error \(error.rawValue)). Nothing changed on screen as far as the system "
                + "reports. Try action: mouse, which clicks the element's own point "
                + "c=\(MonitorMapping.format(element.center.x)),"
                + "\(MonitorMapping.format(element.center.y))."
        }
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        let after = AXRead.stateSummary(live)

        var text = "\(AXActionName.short(axAction)) sent to \(label) at "
            + "c=\(MonitorMapping.format(element.center.x)),"
            + "\(MonitorMapping.format(element.center.y)) "
            + "(frame \(String(format: "%.0fx%.0f", element.sizePoints.width, element.sizePoints.height))pt). "
        text += AXActionVerdict.note(kind: .ax(axAction), before: before, after: after)
        text += " The cursor did not move: this acted on the element itself."
        if let span = args.zoom?.value {
            return await Self.zoomScreenshot(monitor: monitor, span: span,
                                             center: element.center, note: text)
        }
        return await Self.overviewScreenshot(monitor: monitor, extraText: text,
                                             toolName: "computer_target_ax_action")
    }

    // MARK: - Mouse

    /// A real click on the element's own point: the honest test of whether the control answers the
    /// mouse, and the fallback when its AX action is silently ignored.
    private func clickElement(
        _ element: AXElementInfo,
        label: String,
        point: CGPoint,
        before: String,
        double: Bool,
        monitor: Int,
        delay: Double,
        zoom: Double?
    ) async -> String {
        await MainActor.run { Self.activateApp(at: point) }
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
        Self.postMouseMoved(to: point)
        try? await Task.sleep(for: .milliseconds(120))
        let clicks = double ? 2 : 1
        for index in 0..<clicks {
            Self.postMouseEvent(type: .leftMouseDown, point: point, button: .left)
            try? await Task.sleep(for: .milliseconds(30))
            Self.postMouseEvent(type: .leftMouseUp, point: point, button: .left)
            if index < clicks - 1 { try? await Task.sleep(for: .milliseconds(100)) }
        }
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        let after = element.element.map { AXRead.stateSummary($0) } ?? "no readable state"
        var text = "Clicked \(label) at c=\(MonitorMapping.format(element.center.x)),"
            + "\(MonitorMapping.format(element.center.y))"
            + (double ? " (double click)." : ".") + " Real mouse event on the element's own point. "
        text += AXActionVerdict.note(kind: double ? .doubleClick : .mouse,
                                     before: before, after: after)
        if let span = zoom {
            return await Self.zoomScreenshot(monitor: monitor, span: span,
                                             center: element.center, note: text)
        }
        return await Self.overviewScreenshot(monitor: monitor, extraText: text,
                                             toolName: "computer_target_ax_action")
    }

    // MARK: - Refusals

    private func notFoundMessage(_ target: String, appName: String, candidates: [Int],
                                 in elements: [AXElementInfo]) -> String {
        let text = "❌ computer_target_ax_action: nothing in the accessibility tree of \"\(appName)\" "
            + "matches \"\(target)\"."
        if candidates.isEmpty {
            return text + " Call computer_elements to see what is actually on screen."
        }
        let lines = candidates.map { AXElementInfo.line(for: elements[$0], index: $0) }
        return text + " Closest by name:\n" + lines.joined(separator: "\n")
            + "\nUse one of these, or call computer_elements for the current list."
    }

    private func ambiguousMessage(_ target: String, appName: String, indexes: [Int],
                                  in elements: [AXElementInfo]) -> String {
        let text = "❌ computer_target_ax_action: \"\(target)\" matches \(indexes.count) elements in "
            + "\"\(appName)\". Nothing was sent — pick one by appending #n in this order:\n"
        let lines = indexes.enumerated().map { position, index in
            "  #\(position + 1) " + AXElementInfo.line(for: elements[index], index: index)
                .trimmingCharacters(in: .whitespaces)
        }
        return text + lines.joined(separator: "\n")
    }

    private func notAvailableMessage(word: String, label: String, reference: String,
                                     actions: [String]?) -> String {
        let available: String
        switch actions {
        case .none:            available = "its action list could not be read"
        case .some(let list) where list.isEmpty: available = "it declares no actions at all"
        case .some(let list):
            available = "it declares: " + list.map { AXActionName.short($0) }.joined(separator: ", ")
        }
        return "❌ computer_target_ax_action: \(label) does not support \"\(word)\" — \(available). "
            + "Nothing was sent. Use action: mouse to click its point with a real mouse event, or "
            + "one of the declared actions. Element: \(reference)."
    }
}
