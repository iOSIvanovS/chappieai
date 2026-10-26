// ChappieViewModel+Send.swift
// Chappie
//
// send(), cancel, output attachments, cancellation handler.

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

            do {
                let result = try await orchestrator.process(
                    prompt: prompt,
                    history: networkHistory,
                    currentMessage: currentAIMessage,
                    config: config,
                    memoryContext: memoryContext,
                    overrideSystemPrompt: systemPromptOverride,
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
                    },
                    onTerminalOutput: { chunk in
                        Task { @MainActor in self.terminal.append(chunk) }
                    },
                    onTerminalStart: { command in
                        Task { @MainActor in self.terminal.start(command: command) }
                    },
                    onTerminalFinish: {
                        Task { @MainActor in self.terminal.finish() }
                    },
                    onRetry: { status in
                        Task { @MainActor in self.streaming.retryLabel = status?.localizedLabel }
                    },
                    onToolBudget: { seconds in
                        Task { @MainActor in self.setToolBudget(seconds) }
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

                if let threadId = activeThreadId {
                    self.persistMessages(self.messages, threadId: threadId, refreshThreadList: true)
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

    // MARK: - Tool time budget

    /// Starts (seconds != nil) or clears the filling bar of the running tool.
    @MainActor
    func setToolBudget(_ seconds: TimeInterval?) {
        guard let seconds else { streaming.toolBudget = nil; return }
        let now = Date()
        streaming.toolBudget = now...now.addingTimeInterval(seconds)
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

    // MARK: - Cancellation Handler

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

        if let threadId = activeThreadId {
            persistMessages(messages, threadId: threadId)
        }
    }
}
