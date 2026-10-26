// ChappieViewModel+Terminal.swift
// Chappie
//
// Terminal confirmation flow: intercept PendingTerminalCommand, show inline UI,
// execute or reject based on user choice.
//
// FLOW:
//   1. Orchestrator returns a response containing PendingTerminalCommand marker.
//   2. ChappieViewModel+Send detects the marker and calls insertTerminalConfirmation().
//   3. A .terminalConfirmation message is appended — MessageBubbleView renders Run/Cancel.
//   4. User taps Run → approveTerminalCommand() → executes via ToolExecutionService,
//      replaces the confirmation bubble with the result.
//   5. User taps Cancel → rejectTerminalCommand() → replaces bubble with cancelled note.
//
// WHY NOT A SHEET/ALERT:
// Inline UI keeps the confirmation in context — the user sees the command and the
// preceding AI message together. Sheets break flow and lose context.

import SwiftUI
import ChappieCore

extension ChappieViewModel {

    // MARK: - Insert confirmation bubble

    /// Called by ChappieViewModel+Send when a PendingTerminalCommand is detected.
    /// Replaces the AI text response with the confirmation bubble.
    func insertTerminalConfirmation(command: String, threadId: UUID) {
        let bubble = ChatMessage.terminalConfirmation(command: command, threadId: threadId)
        messages.append(bubble)
        appendToDisplayed(bubble)
        scrollToBottomTrigger += 1
    }

    // MARK: - Approve

    /// User tapped "Run" — execute the command and replace the confirmation bubble with the result.
    func approveTerminalCommand(messageId: UUID, command: String) {
        guard let toolService = toolService else {
            replaceConfirmation(id: messageId, with: "❌ Terminal service not available.")
            return
        }

        // Show thinking state while the command runs.
        isThinking = true
        setToolBudget(ToolDeadlines.seconds(tool: "run_terminal", arguments: "{}"))

        // Held in currentRequestTask so the Stop button reaches the command like any other request.
        currentRequestTask = Task {
            let result = await toolService.executeConfirmedCommand(command)
            await MainActor.run {
                self.setToolBudget(nil)
                self.isThinking = false
                self.currentRequestTask = nil
                self.replaceConfirmation(id: messageId, with: result)
                self.saveMessagesIfNeeded()
            }
        }
    }

    // MARK: - Reject

    /// User tapped "Cancel" — replace the confirmation bubble with a cancelled note.
    func rejectTerminalCommand(messageId: UUID, command: String) {
        let note = "*[Terminal command cancelled by user: `\(command)`]*"
        replaceConfirmation(id: messageId, with: note)
        saveMessagesIfNeeded()
    }

    // MARK: - Helpers

    /// Replaces a .terminalConfirmation bubble with a .message containing the given text.
    private func replaceConfirmation(id: UUID, with text: String) {
        let resultMessage = ChatMessage.message(isUser: false, text: text)

        // Replace in full messages array.
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx] = resultMessage
        }

        // Replace in displayed slice.
        if let idx = displayedMessages.firstIndex(where: { $0.id == id }) {
            displayedMessages[idx] = resultMessage
        }

        scrollToBottomTrigger += 1
    }

    /// Persists messages to disk, filtering out ephemeral confirmation bubbles.
    private func saveMessagesIfNeeded() {
        guard let threadId = activeThread?.id else { return }
        // Filter out ephemeral .terminalConfirmation cases before saving.
        persistMessages(messages.filter { !$0.isTerminalConfirmation }, threadId: threadId)
    }
}
