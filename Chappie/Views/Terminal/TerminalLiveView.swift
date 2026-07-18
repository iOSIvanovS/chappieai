// TerminalLiveView.swift
// Chappie
//
// Live terminal output window — shown while run_terminal/run_ssh executes.
// Auto-scrolls to bottom as chunks arrive. Window itself is opened/closed by
// ContentView reacting to TerminalLiveState.isActive (see ChappieApp.swift).

import SwiftUI

struct TerminalLiveView: View {

    let terminal: TerminalLiveState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(terminal.outputText.isEmpty ? " " : terminal.outputText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                        .id("bottom")
                }
                .onChange(of: terminal.outputText) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .background(Color.black)
        .frame(minWidth: 560, minHeight: 320)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal.fill")
                .foregroundStyle(.green)
            Text(terminal.command)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black)
    }
}

#Preview {
    let terminal = TerminalLiveState()
    terminal.start(command: "run_terminal → git status")
    terminal.append("On branch main\nnothing to commit, working tree clean\n")
    return TerminalLiveView(terminal: terminal)
}
