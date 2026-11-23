// ComputerUseTypeTool.swift
// ChappieCore
//
// WHY THIS FILE:
// computer_type: move the cursor to the target field with computer_move_to, then call this tool.
// It clicks the current cursor position to focus the field, pastes the text via ⌘V, and
// optionally presses Return. The user's clipboard is saved and restored around the paste.

import Foundation
import CoreGraphics
import AppKit

extension ToolExecutionService {

    struct AimedTypeArguments: Decodable {
        var text: String
        var submit: FlexBool?
        var delay: FlexDouble?
        var monitor: FlexInt?
    }

    // MARK: - Execution

    func performAimedType(argsData: Data) async -> String {
        guard Self.isAccessibilityTrusted() else {
            return "❌ computer_type: Accessibility permission is required. Grant it in System Settings → Privacy & Security → Accessibility, then try again."
        }
        guard let args = try? JSONDecoder().decode(AimedTypeArguments.self, from: argsData),
              !args.text.isEmpty else {
            return "❌ computer_type: Argument 'text' is required."
        }
        let monitor = args.monitor?.value ?? 0
        let delay   = args.delay?.value ?? 1.0

        // Click the current cursor position to focus the field.
        let pt: CGPoint = await MainActor.run {
            if let ev = CGEvent(source: nil) { return ev.location }
            let loc = NSEvent.mouseLocation
            return CGPoint(x: loc.x, y: CGDisplayBounds(CGMainDisplayID()).height - loc.y)
        }

        await MainActor.run { Self.activateApp(at: pt) }
        CGWarpMouseCursorPosition(pt)
        CGAssociateMouseAndMouseCursorPosition(1)
        try? await Task.sleep(for: .milliseconds(120))
        Self.postMouseEvent(type: .leftMouseDown, point: pt, button: .left)
        Self.postMouseEvent(type: .leftMouseUp,   point: pt, button: .left)
        try? await Task.sleep(for: .milliseconds(150))

        await Self.pasteText(args.text, submit: args.submit?.value == true)
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        return await MainActor.run { Self.overviewScreenshot(monitor: monitor) }
    }

    // MARK: - Paste

    @MainActor
    private static func pasteText(_ text: String, submit: Bool) async {
        let board = NSPasteboard.general
        let saved = snapshotClipboard(board)
        board.clearContents()
        board.setString(text, forType: .string)
        postCommandV()
        // The target app reads the clipboard asynchronously; wait before restoring.
        try? await Task.sleep(for: .milliseconds(250))
        restoreClipboard(saved, to: board)
        if submit {
            postRawKey(keyCode: 36, keyDown: true)
            postRawKey(keyCode: 36, keyDown: false)
        }
    }

    private static func postCommandV() {
        let vKey: CGKeyCode = 9
        let cmdKey: CGKeyCode = 55
        if let e = CGEvent(keyboardEventSource: nil, virtualKey: cmdKey, keyDown: true) {
            e.flags = .maskCommand; e.post(tap: .cghidEventTap)
        }
        for down in [true, false] {
            if let e = CGEvent(keyboardEventSource: nil, virtualKey: vKey, keyDown: down) {
                e.flags = .maskCommand; e.post(tap: .cghidEventTap)
            }
        }
        if let e = CGEvent(keyboardEventSource: nil, virtualKey: cmdKey, keyDown: false) {
            e.flags = []; e.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Clipboard save / restore

    @MainActor
    private static func snapshotClipboard(_ board: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (board.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let d = item.data(forType: type) { entry[type] = d } }
            return entry
        }
    }

    @MainActor
    private static func restoreClipboard(
        _ saved: [[NSPasteboard.PasteboardType: Data]],
        to board: NSPasteboard
    ) {
        board.clearContents()
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }
}
