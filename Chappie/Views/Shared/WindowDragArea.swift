// WindowDragArea.swift
// Chappie
//
// Restores window dragging and title-bar double-click over the empty middle of the toolbar.
//
// WHY THIS EXISTS:
// On macOS 27 the system NSToolbarTitleView (the empty title field between the toolbar
// buttons) stopped forwarding mouse-down to the window's native drag/zoom handling.
// Only the strips left of the traffic lights and right of the last button still worked.
// Overlaying our own view does not help — the title view sits above the content and wins
// hit-testing — so a local event monitor intercepts the click and does it by hand.

import SwiftUI
import AppKit

struct WindowDragArea: NSViewRepresentable {

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ nsView: MonitorView, context: Context) {}

    final class MonitorView: NSView {

        private var monitor: Any?

        // Invisible helper: must never take clicks away from the real content.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Returns nil when the event was consumed, otherwise the untouched event.
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window,
                  let frameView = window.contentView?.superview else { return event }

            let point = frameView.convert(event.locationInWindow, from: nil)
            guard isToolbarTitleView(frameView.hitTest(point)) else { return event }

            if event.clickCount == 2 {
                performDoubleClickAction(in: window)
            } else {
                window.performDrag(with: event)
            }
            return nil
        }

        /// NSToolbarTitleView is private API, so it is matched by class name.
        private func isToolbarTitleView(_ view: NSView?) -> Bool {
            var current = view
            while let candidate = current {
                if String(describing: type(of: candidate)) == "NSToolbarTitleView" { return true }
                current = candidate.superview
            }
            return false
        }

        /// Mirrors the system "Double-click a window's title bar to" preference.
        private func performDoubleClickAction(in window: NSWindow) {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "None":     break
            case "Minimize": window.performMiniaturize(nil)
            default:         window.performZoom(nil)
            }
        }
    }
}
