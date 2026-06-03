// ChappieViewModel+Send.swift
// Chappie
//
// send(), cancel, history building, multimodal encoding, response cleanup.
//
// MULTIMODAL ARCHITECTURE (MULTIMODAL-STEP3):
//   1. User message is stored in messages[] with attachments (for UI + persistence).
//   2. buildRawNetworkHistory(excludingLast:1) returns completed pairs — excludes the new user message.
//   3. buildCurrentAIMessage() encodes the current turn (possibly multimodal) separately.
//   4. orchestrator.process(currentMessage:) appends it as the final user turn.
// WHY: old approach passed full messages[] and relied on string dedup — broke for multimodal
// because contentString is nil, causing double-send.
//
// CANCEL STATE FIX:
// catch blocks dispatch to @MainActor explicitly — currentRequestTask runs in an unstructured
// Task with no MainActor isolation, so withAnimation{} from a background thread is silently
// ignored by SwiftUI. Without this, isThinking stays true and InputMorphView never morphs back.
//
// CANCEL UX (CANCEL-FIX):
// On CancellationError — partial streamingText is preserved as a cancelled message in history.
// This gives the AI context that the previous operation was interrupted by the user, so it
// doesn't get confused on the next message. Format:
//   [partial stream text, if any]
//   ---
//   *(Operation cancelled by user)*
//
// V2 SYSTEM PROMPT + TOOL PERMISSIONS:
// v2SystemPrompt() is awaited → passed as overrideSystemPrompt (AIOrchestrator skips MemoryManager).
// v2ToolPermissions() is awaited → passed as overrideToolPermissions (orchestrator uses
// New.ToolAccessController.check() instead of legacy ToolAccessControl in ToolExecutionService).
//
// NO PROVIDER ALERT:
// When orchestrator is nil (model/provider deleted from under the thread), send() triggers
// showNoProviderAlert instead of injecting a system message into chat history.
// WHY: system messages pollute AI context and confuse history. An alert is ephemeral UI —
// it informs the user without leaving noise in the conversation.

import SwiftUI
import ChappieCore

extension ChappieViewModel {

    // MARK: - Send

    func send(prompt: String, attachments: [AttachedFile] = []) {
        guard !prompt.isEmpty || !attachments.isEmpty else { return }

        print("[B-04] send() entry — activeProvider: \(activeProvider?.displayName ?? "nil"), orchestrator: \(orchestrator != nil ? "set" : "nil")")

        // No provider/model configured — show alert instead of polluting chat history
        guard let orchestrator = orchestrator else {
            showNoProviderAlert = true
            return
        }
        guard activeProvider != nil else {
            showNoProviderAlert = true
            return
        }

        let userMessage = ChatMessage.message(isUser: true, text: prompt, attachments: attachments)
        messages.append(userMessage)
        appendToDisplayed(userMessage)

        isThinking = true
        streamingText = ""
        currentToolCall = nil
        runningCost = 0.0

        let networkHistory = buildRawNetworkHistory(excludingLast: 1)
        let currentAIMessage = buildCurrentAIMessage(text: prompt, attachments: attachments)

        let config = activeConfig
        let memoryContext = activeMemoryContext
        let activeThreadId = activeThread?.id
        let activeProviderId = activeProvider?.id

        currentRequestTask = Task {
            let systemPromptOverride = await v2SystemPrompt()
            let toolPermissionsOverride = await v2ToolPermissions()

            do {
                let result = try await orchestrator.process(
                    prompt: prompt,
                    history: networkHistory,
                    currentMessage: currentAIMessage,
                    config: config,
                    memoryContext: memoryContext,
                    overrideSystemPrompt: systemPromptOverride,
                    overrideToolPermissions: toolPermissionsOverride,
                    onToolCall: { toolName, targetPath in
                        Task { @MainActor in
                            self.currentToolCall = targetPath.isEmpty
                                ? toolName
                                : "\(toolName) → \(targetPath.split(separator: "/").suffix(2).joined(separator: "/"))"
                        }
                    },
                    onToken: { token in
                        Task { @MainActor in self.streamingText += token }
                    },
                    onCostUpdate: { cost in
                        Task { @MainActor in self.runningCost = cost }
                    },
                    onBalanceUpdate: { balance in
                        Task { @MainActor in
                            self.currentBalance = balance
                            if let pid = activeProviderId { self.saveBalance(balance, for: pid) }
                        }
                    }
                )

                let rawResponse = self.cleanAIResponse(result.finalResponse)
                let (displayText, summary) = self.extractAndCleanSummary(from: rawResponse)
                let aiMessage = ChatMessage.message(isUser: false, text: displayText, cost: result.totalCost, summary: summary)

                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    self.streamingText = ""
                    self.currentToolCall = nil
                    self.isThinking = false
                    self.messages.append(aiMessage)
                    self.appendToDisplayed(aiMessage)
                }

                if let newBalance = result.newBalance {
                    self.currentBalance = newBalance
                    if let pid = activeProviderId { self.saveBalance(newBalance, for: pid) }
                }

                if let threadId = activeThreadId, let store = self.threadStore {
                    let currentMessages = self.messages
                    Task { @MainActor in
                        try? await store.saveMessages(currentMessages, toThreadId: threadId)
                        if let refreshed = try? await store.loadThreads() { self.threads = refreshed }
                    }
                }

            } catch is CancellationError {
                print("[ChappieViewModel] Request cancelled by user (CancellationError)")
                Task { @MainActor in
                    self.handleCancellation(activeThreadId: activeThreadId)
                }

            } catch ChappieError.cancelled {
                print("[ChappieViewModel] Request cancelled (URLError.cancelled)")
                Task { @MainActor in
                    self.handleCancellation(activeThreadId: activeThreadId)
                }

            } catch {
                Task { @MainActor in
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                        self.streamingText = ""
                        self.currentToolCall = nil
                        self.isThinking = false
                        let errMessage = ChatMessage.message(isUser: false, text: "Упс, ошибка: \(error.localizedDescription)")
                        self.messages.append(errMessage)
                        self.appendToDisplayed(errMessage)
                    }
                }
            }

            self.currentRequestTask = nil
        }
    }

    // MARK: - Cancel

    func cancelCurrentRequest() {
        guard let task = currentRequestTask else { return }
        print("[ChappieViewModel] Cancelling current request...")
        task.cancel()
    }

    // MARK: - Private: Cancellation Handler

    /// Cleans up UI state and adds a cancelled message to history.
    ///
    /// WHY ADD TO HISTORY:
    /// If partial stream text exists, the AI needs to know the operation was interrupted —
    /// otherwise on the next message it may think its previous response was complete.
    @MainActor
    private func handleCancellation(activeThreadId: UUID?) {
        let partial = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastTool = currentToolCall

        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
            self.streamingText = ""
            self.currentToolCall = nil
            self.isThinking = false
        }

        let cancelledText: String
        if partial.isEmpty {
            if let tool = lastTool {
                cancelledText = "*[Operation cancelled by user while executing: \(tool)]*"
            } else {
                cancelledText = "*[Operation cancelled by user]*"
            }
        } else {
            cancelledText = partial + "\n\n---\n*[Response interrupted by user. Operation cancelled.]*"
        }

        let cancelledMessage = ChatMessage.message(
            isUser: false,
            text: cancelledText,
            summary: "User cancelled this operation. The response above is incomplete."
        )

        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            self.messages.append(cancelledMessage)
            self.appendToDisplayed(cancelledMessage)
        }

        if let threadId = activeThreadId, let store = self.threadStore {
            let currentMessages = self.messages
            Task {
                try? await store.saveMessages(currentMessages, toThreadId: threadId)
            }
        }
    }

    // MARK: - V2 Tool Permissions

    /// Returns ToolPermissions from the active ThreadSession, nil if no session.
    func v2ToolPermissions() async -> New.ToolPermissions? {
        guard let session = _activeThreadSession else { return nil }
        return try? await session.toolPermissions()
    }

    // MARK: - Build Network History

    /// Returns AIMessage history excluding the last N messages.
    /// In send(), excludingLast:1 removes the just-appended user message — it's passed separately as currentMessage.
    func buildRawNetworkHistory(excludingLast: Int = 0) -> [AIMessage] {
        let sourceMessages = excludingLast > 0 && messages.count > excludingLast
            ? Array(messages.dropLast(excludingLast))
            : messages

        return sourceMessages.compactMap { msg -> AIMessage? in
            guard case .message(_, let isUser, let text, _, let summary, let attachments) = msg else { return nil }

            let isSystemMessage = text.contains("Проект подключен")
                || text.contains("Память очищена")
                || text.contains("API-ключ обновлён")
                || text.hasPrefix("⚠️")
                || text.hasPrefix("Ошибка:")
                || text.hasPrefix("Упс, ошибка:")
            if isSystemMessage { return nil }

            let role = isUser ? "user" : "assistant"

            if !isUser {
                if let summary = summary {
                    return AIMessage(role: role, content: text + "\n<summary>\(summary)</summary>")
                }
                return AIMessage(role: role, content: text)
            }

            if !attachments.isEmpty {
                var parts: [AIMultimodalPart] = []
                if !text.isEmpty { parts.append(.text(text)) }
                for attachment in attachments { parts.append(multimodalPart(for: attachment)) }
                return AIMessage(role: role, multimodalParts: parts)
            }

            return AIMessage(role: role, content: text)
        }
    }

    /// Builds the AIMessage for the current user turn (possibly multimodal).
    func buildCurrentAIMessage(text: String, attachments: [AttachedFile]) -> AIMessage {
        guard !attachments.isEmpty else { return AIMessage(role: "user", content: text) }

        var parts: [AIMultimodalPart] = []
        if !text.isEmpty { parts.append(.text(text)) }
        for attachment in attachments { parts.append(multimodalPart(for: attachment)) }
        return AIMessage(role: "user", multimodalParts: parts)
    }

    /// Converts an AttachedFile to the appropriate AIMultimodalPart.
    /// Images → base64 data URI; text/PDF → inline text; unknown → filename + size note.
    func multimodalPart(for attachment: AttachedFile) -> AIMultimodalPart {
        switch attachment.mimeType {
        case .imageJpeg, .imagePng, .imageGif, .imageWebp:
            return .imageURL(attachment.dataURI)

        case .plainText:
            let content = String(data: attachment.data, encoding: .utf8)
                ?? String(data: attachment.data, encoding: .isoLatin1)
                ?? "[Could not decode text content]"
            return .text("File: \(attachment.filename)\n\n\(content)")

        case .pdf:
            if let text = String(data: attachment.data, encoding: .utf8), !text.isEmpty {
                return .text("File: \(attachment.filename)\n\n\(text)")
            }
            return .text("File: \(attachment.filename) (PDF, \(attachment.data.count / 1024)KB) — binary content, cannot extract text inline.")

        case .other:
            return .text("File: \(attachment.filename) (\(attachment.mimeType.rawValue), \(attachment.data.count / 1024)KB)")
        }
    }

    // MARK: - Self-Summary Parsing

    /// Extracts the last <summary>…</summary> tag from the AI response.
    /// Returns (displayText without the tag, summary string or nil).
    func extractAndCleanSummary(from text: String) -> (displayText: String, summary: String?) {
        guard let regex = try? NSRegularExpression(
            pattern: "<summary>(.*?)</summary>",
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return (text, nil) }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        guard let lastMatch = matches.last,
              let summaryRange = Range(lastMatch.range(at: 1), in: text),
              let fullMatchRange = Range(lastMatch.range, in: text) else { return (text, nil) }

        let summary = String(text[summaryRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        var displayText = text
        displayText.removeSubrange(fullMatchRange)
        displayText = displayText.trimmingCharacters(in: .whitespacesAndNewlines)

        return (displayText.isEmpty ? summary : displayText, summary.isEmpty ? nil : summary)
    }

    // MARK: - Response Cleanup

    /// Strips internal model reasoning artifacts (e.g. "94>thought…needed.") from the response.
    func cleanAIResponse(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: "94>thought.*?needed\\.\\n*", options: [.dotMatchesLineSeparators]) {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
