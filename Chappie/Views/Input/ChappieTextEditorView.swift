// ChappieTextEditorView.swift
// Chappie
//
// NSTextView subclass + NSViewRepresentable wrapper for the main input field.
//
// WHY NSTextView subclass:
// SwiftUI's onKeyPress on TextEditor is unreliable on macOS — AppKit consumes key events first.
// Subclassing ChappieTextView is the ONLY guaranteed way to intercept plain Enter vs Shift+Enter.

import SwiftUI
import AppKit

// MARK: - ChappieTextView

/// NSTextView subclass with direct keyDown interception.
final class ChappieTextView: NSTextView {

    /// Fired when the user presses plain Enter (no modifiers). Triggers message send.
    var onSend: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // keyCode 36 = Return / Enter
        guard event.keyCode == 36 else {
            super.keyDown(with: event)
            return
        }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if mods.contains(.shift) || mods.contains(.option) {
            // Shift+Enter or Option+Enter → insert real newline at cursor position
            insertNewline(nil)
        } else {
            // Plain Enter → trigger send
            onSend?()
        }
    }
}

// MARK: - ChappieTextEditorView

/// NSViewRepresentable wrapping ChappieTextView inside an NSScrollView.
/// Exposes text binding, height change callback, focus change callback,
/// and surfaces Coordinator for imperative focus control.
struct ChappieTextEditorView: NSViewRepresentable {

    @Binding var text: String
    var isEnabled: Bool
    var onSend: () -> Void
    var onHeightChange: (CGFloat) -> Void
    var onFocusChange: ((Bool) -> Void)?
    var onCoordinatorReady: ((Coordinator) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        let textView = ChappieTextView()
        textView.onSend = { [weak coordinator] in
            coordinator?.parent.onSend()
        }
        textView.delegate = coordinator
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 4, height: InputLayout.editorVerticalPadding)
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        // Vertical scroller is intentionally OFF — panel height is managed by editorHeight state.
        // autohidesScrollers=true still reserves scrollbar width before hiding, causing text
        // field width to jitter as the user types. Disabling it entirely eliminates the jitter.
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        coordinator.textView = textView

        DispatchQueue.main.async {
            coordinator.parent.onCoordinatorReady?(coordinator)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ChappieTextView else { return }

        let coordinator = context.coordinator
        textView.onSend = { [weak coordinator] in
            coordinator?.parent.onSend()
        }

        // Sync text only when changed externally (e.g. cleared after send)
        if textView.string != text {
            textView.string = text
            // Recalculate height after layout pass so layoutManager has fresh data
            DispatchQueue.main.async {
                coordinator.recalculateHeight(textView)
            }
        }

        textView.isEditable = isEnabled
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChappieTextEditorView
        weak var textView: ChappieTextView?

        init(parent: ChappieTextEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            recalculateHeight(tv)
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocusChange?(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onFocusChange?(false)
        }

        /// Measures real rendered height using NSLayoutManager.
        /// This correctly handles word-wrap — unlike counting "\n" characters.
        func recalculateHeight(_ textView: NSTextView) {
            guard
                let layoutManager = textView.layoutManager,
                let textContainer = textView.textContainer
            else { return }

            // Force layout to be up to date before measuring
            layoutManager.ensureLayout(for: textContainer)

            let usedRect = layoutManager.usedRect(for: textContainer)
            // usedRect.height reflects actual rendered lines including word-wrap
            let contentHeight = usedRect.height + InputLayout.editorVerticalPadding * 2
            let clamped = min(contentHeight, InputLayout.maxEditorHeight)
            let final = max(clamped, InputLayout.minEditorHeight)

            parent.onHeightChange(final)
        }

        /// Makes the underlying NSTextView first responder.
        func focus() {
            textView?.window?.makeFirstResponder(textView)
        }
    }
}
