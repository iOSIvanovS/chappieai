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

        // Persist Office attachments to Application Support before appending to history.
        let persistedAttachments = persistAttachments(attachments, forMessageId: userMessageId)

        let userMessage = ChatMessage.message(id: userMessageId, isUser: true, text: prompt, attachments: persistedAttachments)
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
            let currentAIMessage = await buildCurrentAIMessage(text: prompt, attachments: persistedAttachments)

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

                // Build output file attachments from write_document results.
                // Each file gets its own AttachedFile bubble in the AI message.
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

    // MARK: - Persist Attachments

    /// Copies Office documents to permanent storage in Application Support.
    /// Images are left as-is (stored inline as base64).
    private func persistAttachments(_ attachments: [AttachedFile], forMessageId messageId: UUID) -> [AttachedFile] {
        attachments.map { file in
            guard file.mimeType.isOfficeDocument, file.localURL == nil else { return file }
            if let url = AttachmentStore.shared.save(data: file.data, filename: file.filename, forMessageId: messageId) {
                return file.withLocalURL(url)
            }
            return file
        }
    }

    // MARK: - Output File Attachments

    /// Converts write_document output paths into AttachedFile instances for bubble display.
    /// Files are already on disk — we just read their data and wrap them.
    private func buildOutputAttachments(from paths: [String], forMessageId messageId: UUID) -> [AttachedFile] {
        paths.compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: url) else {
                print("[ChappieViewModel] Output file not readable at: \(path)")
                return nil
            }
            let mime = AttachmentMimeType.from(url: url)
            return AttachedFile(
                filename: url.lastPathComponent,
                mimeType: mime,
                data: data,
                localURL: url
            )
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

    /// Returns AIMessage history excluding the last N messages.
    func buildRawNetworkHistory(excludingLast: Int = 0) -> [AIMessage] {
        let sourceMessages = excludingLast > 0 && messages.count > excludingLast
            ? Array(messages.dropLast(excludingLast))
            : messages

        return sourceMessages.compactMap { msg -> AIMessage? in
            guard case .message(_, let isUser, let text, _, let attachments) = msg else { return nil }

            // Filter out transient system messages that should not be sent to the AI.
            let isSystemMessage = text.contains("Project connected")
                || text.contains("Memory cleared")
                || text.contains("API key updated")
                || text.hasPrefix("⚠️")
                || text.hasPrefix("Error:")
                || text.hasPrefix("Oops, error:")
            if isSystemMessage { return nil }

            let role = isUser ? "user" : "assistant"

            if !isUser {
                return AIMessage(role: role, content: text)
            }

            if !attachments.isEmpty {
                var parts: [AIMultimodalPart] = []
                if !text.isEmpty { parts.append(.text(text)) }
                for attachment in attachments { parts.append(multimodalPartSync(for: attachment)) }
                return AIMessage(role: role, multimodalParts: parts)
            }

            return AIMessage(role: role, content: text)
        }
    }

    /// Builds the AIMessage for the current user turn — async to support Office extraction.
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

    /// Converts an AttachedFile to AIMultimodalPart — async for Office document extraction.
    func multimodalPart(for attachment: AttachedFile) async -> AIMultimodalPart {
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

        case .docx, .xlsx, .pptx, .rtf:
            return await extractOfficeDocument(attachment)

        case .other:
            return .text("File: \(attachment.filename) (\(attachment.mimeType.rawValue), \(attachment.data.count / 1024)KB)")
        }
    }

    /// Sync fallback for history reconstruction — no MCP call, just a note.
    private func multimodalPartSync(for attachment: AttachedFile) -> AIMultimodalPart {
        switch attachment.mimeType {
        case .imageJpeg, .imagePng, .imageGif, .imageWebp:
            return .imageURL(attachment.dataURI)
        case .plainText:
            let content = String(data: attachment.data, encoding: .utf8)
                ?? "[Could not decode text content]"
            return .text("File: \(attachment.filename)\n\n\(content)")
        case .pdf:
            return .text("File: \(attachment.filename) (PDF, \(attachment.data.count / 1024)KB)")
        case .docx, .xlsx, .pptx, .rtf:
            return .text("File: \(attachment.filename) [\(attachment.mimeType.rawValue), previously extracted]")
        case .other:
            return .text("File: \(attachment.filename) (\(attachment.mimeType.rawValue), \(attachment.data.count / 1024)KB)")
        }
    }

    /// Extracts Office document content via read_document (ZIP+XML pipeline in ChappieMCP).
    private func extractOfficeDocument(_ attachment: AttachedFile) async -> AIMultimodalPart {
        guard let toolService else {
            return .text("File: \(attachment.filename) — tool service unavailable")
        }

        if let localURL = attachment.localURL {
            return await callReadDocument(path: localURL.path, filename: attachment.filename, toolService: toolService)
        }

        let ext = attachment.filename.split(separator: ".").last.map(String.init) ?? "docx"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChappieDoc-\(UUID().uuidString).\(ext)")

        do {
            try attachment.data.write(to: tempURL)
        } catch {
            return .text("File: \(attachment.filename) — could not write temp file: \(error.localizedDescription)")
        }

        defer { try? FileManager.default.removeItem(at: tempURL) }
        return await callReadDocument(path: tempURL.path, filename: attachment.filename, toolService: toolService)
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

    // MARK: - Response Cleanup

    func cleanAIResponse(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: "94>thought.*?needed\\.\\n*", options: [.dotMatchesLineSeparators]) {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
