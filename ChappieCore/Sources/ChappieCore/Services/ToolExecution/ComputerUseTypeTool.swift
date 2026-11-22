// ComputerUseTypeTool.swift
// ChappieCore
//
// WHY THIS FILE:
// computer_type through the aim: the model aims at a field, then typing clicks the aimed point to
// focus it and pastes the text. Pasting is one atomic action, unlike posting keystrokes one by one,
// and it handles any Unicode. The user's clipboard is saved and restored around the paste.

import Foundation
import CoreGraphics
import AppKit

extension ToolExecutionService {

    /// Arguments of computer_type. No coordinates: the point comes from the pending aim.
    struct AimedTypeArguments: Decodable {
        var text: String
        var submit: FlexBool?
        var delay: FlexDouble?
    }

    // MARK: - Execution

    func performAimedType(argsData: Data) async -> String {
        guard Self.isAccessibilityTrusted() else {
            return "❌ computer_type: Accessibility permission is required. Please grant it in System Settings → Privacy & Security → Accessibility, then try again."
        }
        guard let args = try? JSONDecoder().decode(AimedTypeArguments.self, from: argsData),
              !args.text.isEmpty else {
            return "❌ computer_type: Argument 'text' is required."
        }
        // take() forgets the aim at once, so a failed or finished action never reuses a stale point.
        guard let aim = Self.aimStore.take() else {
            return "❌ computer_type: No aim is set. Call computer_aim at the input field first, check the crosshair, then type. An aim is used up by one click or type."
        }
        let delay = args.delay?.value ?? 1.0
        await Self.focusAndPaste(text: args.text, at: aim.eventPoint, submit: args.submit?.value == true)
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        return await MainActor.run {
            Self.overviewScreenshot(monitor: aim.monitor, grid: false)
        }
    }

    // MARK: - Focus and paste

    @MainActor
    private static func focusAndPaste(text: String, at point: CGPoint, submit: Bool) async {
        // Keystrokes go to the active app, so hand focus to the app under the aimed point first.
        activateApp(at: point)
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
        try? await Task.sleep(for: .milliseconds(120))
        postMouseEvent(type: .leftMouseDown, point: point, button: .left)
        postMouseEvent(type: .leftMouseUp, point: point, button: .left)
        try? await Task.sleep(for: .milliseconds(150))

        let board = NSPasteboard.general
        let saved = snapshot(board)
        board.clearContents()
        board.setString(text, forType: .string)
        postCommandV()
        // The target app reads the clipboard asynchronously; restoring too early pastes the old content.
        try? await Task.sleep(for: .milliseconds(250))
        restore(saved, to: board)

        if submit {
            postRawKey(keyCode: 36, keyDown: true)
            postRawKey(keyCode: 36, keyDown: false)
        }
    }

    private static func postCommandV() {
        let vKey: CGKeyCode = 9
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: vKey, keyDown: down) else { continue }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Clipboard save and restore

    @MainActor
    private static func snapshot(_ board: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (board.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
    }

    @MainActor
    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to board: NSPasteboard) {
        board.clearContents()
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }
}
