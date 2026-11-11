// ChappieViewModel+Terminal.swift
// Chappie
//
// Terminal confirmation flow. The orchestrator PAUSES the run_terminal call and asks us (through
// `terminalConfirmHandler`); we show a modal Run/Cancel sheet and suspend until the user decides.
// The orchestrator then continues with the real outcome: command output, or "user declined".
//
// FLOW:
//   1. Orchestrator meets the confirmation marker of run_terminal and calls the handler.
//   2. presentTerminalConfirmation() queues a TerminalPrompt and registers a gate; ContentView shows the sheet.
//   3. Run  → gate.resolve(.run)     → orchestrator runs the command and feeds the output to the model.
//   4. Cancel / Esc → gate.resolve(.decline) → orchestrator tells the model the user declined.
//   5. Stop button → the request task is cancelled → the gate resolves .decline by itself.
//
// WHY A SHEET, NOT A CHAT BUBBLE:
// A bubble lives in the message list of the active thread: it landed below the input bar without
// scrolling and vanished from view when the user switched threads while the request kept waiting.
// A sheet cannot be missed, does not depend on scrolling and survives thread switches.

import SwiftUI
import ChappieCore

/// One command waiting for the user's decision.
struct TerminalPrompt: Identifiable, Equatable {
    let id = UUID()
    let command: String
    let threadId: UUID
}

extension ChappieViewModel {

    // MARK: - Handler passed to the orchestrator

    /// Builds the handler for one request. Runs off the main actor, so every UI touch hops to it.
    func terminalConfirmHandler() -> TerminalConfirmationHandler {
        { [weak self] pending in
            guard let self else { return .decline }
            let gate = TerminalDecisionGate()
            let promptId = await MainActor.run { self.presentTerminalConfirmation(pending, gate: gate) }
            let decision = await gate.wait()
            await MainActor.run { self.dismissTerminalConfirmation(id: promptId) }
            return decision
        }
    }

    // MARK: - Sheet state

    /// The prompt the sheet shows now; later ones wait in the queue.
    var currentTerminalPrompt: TerminalPrompt? { terminalPrompts.first }

    /// Title of the thread that asked, so the user knows which conversation the command belongs to.
    func terminalPromptThreadTitle(_ prompt: TerminalPrompt) -> String? {
        threads.first(where: { $0.id == prompt.threadId })?.title
    }

    /// Queues the prompt and remembers the gate its buttons will resolve.
    private func presentTerminalConfirmation(_ pending: PendingTerminalCommand, gate: TerminalDecisionGate) -> UUID {
        let prompt = TerminalPrompt(command: pending.command, threadId: pending.threadId)
        pendingTerminalGates[prompt.id] = gate
        terminalPrompts.append(prompt)
        return prompt.id
    }

    /// Removes the prompt after the decision (or after Stop). The result reaches the user through
    /// the live terminal window and the model's next message.
    private func dismissTerminalConfirmation(id: UUID) {
        pendingTerminalGates[id] = nil
        terminalPrompts.removeAll { $0.id == id }
    }

    // MARK: - Buttons

    /// User chose "Run".
    func approveTerminalCommand(_ prompt: TerminalPrompt) {
        pendingTerminalGates[prompt.id]?.resolve(.run)
    }

    /// User chose "Cancel" or pressed Esc: leave a visible note in the chat when the asking thread is open;
    /// the model is told by the orchestrator.
    func rejectTerminalCommand(_ prompt: TerminalPrompt) {
        guard let gate = pendingTerminalGates[prompt.id] else { return }
        if activeThread?.id == prompt.threadId {
            let note = ChatMessage.message(isUser: false, text: "*[Terminal command declined by user: `\(prompt.command)`]*")
            messages.append(note)
            appendToDisplayed(note)
            scrollToBottomTrigger += 1
        }
        gate.resolve(.decline)
    }
}
