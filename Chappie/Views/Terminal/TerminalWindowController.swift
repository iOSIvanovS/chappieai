// TerminalWindowController.swift
// Chappie
//
// Invisible helper view that opens/closes the "terminal-live" Window scene
// in response to TerminalLiveState.isActive — isolated from ContentView so
// terminal start/stop does not invalidate the main content tree.

import SwiftUI

struct TerminalWindowController: View {

    let terminal: TerminalLiveState

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: terminal.isActive) { _, isActive in
                if isActive {
                    openWindow(id: "terminal-live")
                } else {
                    dismissWindow(id: "terminal-live")
                }
            }
    }
}
