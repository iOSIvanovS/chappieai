// ChappieViewModel+Send.swift
// Chappie
//
// send(), cancel, history building, multimodal encoding, response cleanup.

import SwiftUI
import ChappieCore

extension ChappieViewModel {

    // MARK: - Send

    func send(prompt: String, attachments: [AttachedFile] = []) {
        guard !prompt.isEmpty || !attachments.isEmpty else { return }

        // License gate: block sending if no valid license.
        guard canSendMessages else {
            print("[License] send() blocked — state: \(licenseState)")
            return
        }

        print("[B-04] send() entry — activeProvider: \(activeProvider?.displayName ?? "nil"), orchestrator: \(orchestrator != nil ? "set" : "nil")")

        guard let orchestrator = orchestrator else {
            showNoProviderAlert = true
            return
        }
        guard activeProvider != nil else {
            showNoProviderAlert = true
            return
        }

        let userMessageId = UUID()

        // Attachments are already saved to disk by AttachedFile.load(from:) at pick time.
        // No extra persist step needed — localURL is always set.
        let userMessage = ChatMessage.message(id: userMessageId, isUser: true, text: prompt, attachments: attachments)
        messages.append(userMessage)
        appendToDisplayed(userMessage)

        isThinking = true
        streamingText = ""
        currentToolCall = nil
        runningCost = 0.0

        let networkHistory = buildRawNetworkHistory(excludingLast: 1)

        let config = activeConfig
        let memoryContext = activeMemoryContext
        let activeThreadId = activeThread?.id
        let activeProviderId = activeProvider?.id

        currentRequestTask = Task {
            let currentAIMessage = await buildCurrentAIMessage(text: prompt, attachments: attachments)

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

                if let pending = PendingTerminalCommand.decode(from: rawResponse) {
                    Task { @MainActor in
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                            self.streamingText = ""
                            self.currentToolCall = nil
                            self.isThinking = false
                        }
                        self.insertTerminalConfirmation(command: pending.command, threadId: pending.threadId)
                    }
                    self.currentRequestTask = nil
                    return
                }

                // Build output file attachments from write_document / send_attachment results.
                let aiMessageId = UUID()
                let outputAttachments = buildOutputAttachments(from: result.outputFiles, forMessageId: aiMessageId)

                let aiMessage = ChatMessage.message(
                    id: aiMessageId,
                    isUser: false,
                    text: rawResponse,
                    cost: result.totalCost,
                    attachments: outputAttachments
                )

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
                        let errMessage = ChatMessage.message(
                            isUser: false,
                            text: String(format: String(localized: "error.generic"), error.localizedDescription)
                        )
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

    // MARK: - Output File Attachments

    /// Builds AttachedFile list from paths collected by AIOrchestrator (write_document / send_attachment).
    private func buildOutputAttachments(from paths: [String], forMessageId messageId: UUID) -> [AttachedFile] {
        paths.compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                print("[ChappieViewModel] Output file not found at: \(path)")
                return nil
            }
            return AttachedFile.fromOutputFile(at: url)
        }
    }

    // MARK: - Private: Cancellation Handler

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

        let cancelledMessage = ChatMessage.message(isUser: false, text: cancelledText)

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

    func v2ToolPermissions() async -> ToolPermissions? {
        guard let session = _activeThreadSession else { return nil }
        return try? await session.toolPermissions()
    }

    // MARK: - Build Network History

    func buildRawNetworkHistory(excludingLast: Int = 0) -> [AIMessage] {
        let sourceMessages = excludingLast > 0 && messages.count > excludingLast
            ? Array(messages.dropLast(excludingLast))
            : messages

        return sourceMessages.compactMap { msg -> AIMessage? in
            guard case .message(_, let isUser, let text, _, let attachments) = msg else { return nil }

            let isSystemMessage = text.contains("Project connected")
                || text.contains("Memory cleared")
                || text.contains("API key updated")
                || text.hasPrefix("⚠️")
                || text.hasPrefix("Error:")
                || text.hasPrefix("Oops, error:")
            if isSystemMessage { return nil }

            let role = isUser ? "user" : "assistant"

            if !isUser {
                // AI messages: append attachment reference blocks so the model knows what files exist.
                // Actual bytes are never sent — AI uses fetch_attachment(uuid) to read on demand.
                if !attachments.isEmpty {
                    let refs = attachments.map { "[\(attachmentReferenceText(for: $0))]" }.joined(separator: "\n")
                    let combined = text.isEmpty ? refs : "\(text)\n\n\(refs)"
                    return AIMessage(role: role, content: combined)
                }
                return AIMessage(role: role, content: text)
            }

            // User messages: build multimodal content for images; text refs for everything else.
            if !attachments.isEmpty {
                var parts: [AIMultimodalPart] = []
                if !text.isEmpty { parts.append(.text(text)) }
                for attachment in attachments {
                    parts.append(multimodalPartSync(for: attachment))
                }
                return AIMessage(role: role, multimodalParts: parts)
            }

            return AIMessage(role: role, content: text)
        }
    }

    func buildCurrentAIMessage(text: String, attachments: [AttachedFile]) async -> AIMessage {
        guard !attachments.isEmpty else { return AIMessage(role: "user", content: text) }

        var parts: [AIMultimodalPart] = []
        if !text.isEmpty { parts.append(.text(text)) }
        for attachment in attachments {
            let part = await multimodalPart(for: attachment)
            parts.append(part)
        }
        return AIMessage(role: "user", multimodalParts: parts)
    }

    func multimodalPart(for attachment: AttachedFile) async -> AIMultimodalPart {
        switch attachment.mimeType {
        case .imageJpeg, .imagePng, .imageGif, .imageWebp:
            // Images are sent inline as base64 — small enough to be worth it.
            guard let data = try? Data(contentsOf: attachment.localURL) else {
                return .text(attachmentReferenceText(for: attachment))
            }
            let dataURI = "data:\(attachment.mimeType.rawValue);base64,\(data.base64EncodedString())"
            return .imageURL(dataURI)

        case .plainText:
            guard let data = try? Data(contentsOf: attachment.localURL) else {
                return .text(attachmentReferenceText(for: attachment))
            }
            let content = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? "[Could not decode text content]"
            return .text("File: \(attachment.filename)\n\n\(content)")

        case .pdf:
            guard let data = try? Data(contentsOf: attachment.localURL) else {
                return .text(attachmentReferenceText(for: attachment))
            }
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                return .text("File: \(attachment.filename)\n\n\(text)")
            }
            let size = (try? attachment.localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return .text("File: \(attachment.filename) (PDF, \(size / 1024)KB) — binary content, cannot extract text inline.")

        case .docx, .xlsx, .pptx, .rtf:
            return await extractOfficeDocument(attachment)

        case .other:
            let size = (try? attachment.localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return .text("File: \(attachment.filename) (\(attachment.mimeType.rawValue), \(size / 1024)KB)")
        }
    }

    private func multimodalPartSync(for attachment: AttachedFile) -> AIMultimodalPart {
        switch attachment.mimeType {
        case .imageJpeg, .imagePng, .imageGif, .imageWebp:
            guard let data = try? Data(contentsOf: attachment.localURL) else {
                return .text(attachmentReferenceText(for: attachment))
            }
            let dataURI = "data:\(attachment.mimeType.rawValue);base64,\(data.base64EncodedString())"
            return .imageURL(dataURI)
        case .plainText:
            guard let data = try? Data(contentsOf: attachment.localURL),
                  let content = String(data: data, encoding: .utf8) else {
                return .text(attachmentReferenceText(for: attachment))
            }
            return .text("File: \(attachment.filename)\n\n\(content)")
        case .pdf:
            let size = (try? attachment.localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return .text("File: \(attachment.filename) (PDF, \(size / 1024)KB)")
        case .docx, .xlsx, .pptx, .rtf:
            // Sync path: reference only. Full extraction happens in buildCurrentAIMessage (async).
            return .text(attachmentReferenceText(for: attachment))
        case .other:
            let size = (try? attachment.localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return .text("File: \(attachment.filename) (\(attachment.mimeType.rawValue), \(size / 1024)KB)")
        }
    }

    private func extractOfficeDocument(_ attachment: AttachedFile) async -> AIMultimodalPart {
        guard let toolService else {
            return .text("File: \(attachment.filename) — tool service unavailable")
        }
        return await callReadDocument(path: attachment.localURL.path, filename: attachment.filename, toolService: toolService)
    }

    private func callReadDocument(path: String, filename: String, toolService: ToolExecutionService) async -> AIMultimodalPart {
        let args = "{\"path\":\"\(path)\"}"
        let fakeCall = AIToolCall(
            id: "attachment-\(UUID().uuidString)",
            type: "function",
            function: AIToolCallFunction(name: "read_document", arguments: args)
        )
        let result = await toolService.execute(call: fakeCall)
        return .text("File: \(filename)\n\n\(result)")
    }

    /// Text reference block for an attachment in AI history.
    /// Format: "Attachment: Plan.docx | uuid: 550e8400-..."
    private func attachmentReferenceText(for attachment: AttachedFile) -> String {
        "Attachment: \(attachment.filename) | uuid: \(attachment.id.uuidString)"
    }

    // MARK: - Response Cleanup

    func cleanAIResponse(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: "94>thought.*?needed\\.\\n*", options: [.dotMatchesLineSeparators]) {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
