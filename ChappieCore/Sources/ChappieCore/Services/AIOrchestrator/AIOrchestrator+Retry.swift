import Foundation

extension AIOrchestrator {

    // MARK: - Retry Wrapper (Stall + Timeout)

    func streamWithRetry(
        systemPrompt: String,
        sessionHistory: [AIMessage],
        tools: [AITool],
        config: AppConfig,
        onToken: (@Sendable (String) -> Void)?
    ) async throws -> AIStreamResult {

        var retryHistory = sessionHistory
        var stallRetryCount = 0
        var accumulatedPartialText = ""
        var timeoutAttempt = 0

        while true {
            let log = RequestLog(
                attemptNumber: timeoutAttempt + 1,
                messageCount: retryHistory.count,
                estimatedTokens: retryHistory.reduce(0) { $0 + estimateTokens($1) },
                toolCount: tools.count,
                recentFilePaths: extractRecentFilePaths(from: retryHistory)
            )

            do {
                let result = try await aiClient.streamRequestWithTools(
                    systemPrompt: systemPrompt,
                    chatHistory: retryHistory,
                    tools: tools,
                    stallTimeout: config.stallTimeoutSeconds,
                    onToken: onToken
                )

                if accumulatedPartialText.isEmpty { return result }
                return AIStreamResult(
                    text: accumulatedPartialText + result.text,
                    toolCalls: result.toolCalls,
                    cost: result.cost,
                    balance: result.balance
                )

            } catch let stallError as StallError {
                stallRetryCount += 1
                print("[AIOrchestrator] Stall retry \(stallRetryCount)/\(config.maxStallRetries). Partial: \(stallError.partialText.count) chars.")

                if stallRetryCount > config.maxStallRetries {
                    throw ChappieError.networkError(
                        "Stream stalled \(config.maxStallRetries) times in a row. " +
                        "The provider may be overloaded. Please try again."
                    )
                }

                accumulatedPartialText += stallError.partialText
                if !stallError.partialText.isEmpty {
                    retryHistory.append(AIMessage(role: "assistant", content: stallError.partialText))
                }
                retryHistory.append(AIMessage(
                    role: "user",
                    content: "[SYSTEM: Your previous response was interrupted by a network stall. " +
                             "Continue EXACTLY from where you left off. " +
                             "Do NOT repeat what you already wrote. " +
                             "Do NOT add any preamble. Just continue the response.]"
                ))
                print("[AIOrchestrator] Retrying with continuation prompt. History: \(retryHistory.count) msgs.")

            } catch {
                guard isTimeoutError(error) else { throw error }

                timeoutAttempt += 1
                print("[AIOrchestrator] Timeout on attempt \(timeoutAttempt). Error: \(error.localizedDescription)")

                if timeoutAttempt == 1 {
                    print("[AIOrchestrator] Silent retry in 2s...")
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !isInvalidated else { throw CancellationError() }
                    continue
                }

                print("[AIOrchestrator] Double timeout. Running diagnostic request...")
                let diagnosis = await runDiagnosticRequest(log: log, systemPrompt: systemPrompt)
                return AIStreamResult(text: diagnosis, toolCalls: nil, cost: nil, balance: nil)
            }
        }
    }

    // MARK: - Timeout Detection

    func isTimeoutError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut || urlError.code == .networkConnectionLost
        }
        if case .networkError(let msg) = error as? ChappieError {
            let lower = msg.lowercased()
            return lower.contains("timed out") || lower.contains("timeout") || lower.contains("time out")
        }
        return false
    }

    // MARK: - Diagnostic Request

    func runDiagnosticRequest(log: RequestLog, systemPrompt: String) async -> String {
        let diagnosticPrompt = """
        A user's request to you timed out twice in a row. Here are the request metadata:

        \(log.diagnosticSummary)

        Based on this metadata, provide a SHORT (3-5 sentences) diagnosis in Russian:
        1. What likely caused the timeout (context too large, file too big, task too complex, etc.)
        2. A concrete recommendation for the user (split the task, start a new thread, reduce context, etc.)

        Be specific and practical. Do NOT apologize excessively. Just diagnose and advise.
        """

        do {
            let result = try await aiClient.streamRequestWithTools(
                systemPrompt: "You are a helpful AI assistant diagnosing a timeout issue.",
                chatHistory: [AIMessage(role: "user", content: diagnosticPrompt)],
                tools: [],
                stallTimeout: 30,
                onToken: nil
            )
            let diagnosis = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !diagnosis.isEmpty {
                return "⏱️ **Запрос завис дважды. Вот что я думаю:**\n\n\(diagnosis)"
            }
        } catch {
            print("[AIOrchestrator] Diagnostic request also failed: \(error.localizedDescription)")
        }

        return """
        ⏱️ **Запрос завис дважды подряд.**

        Возможные причины:
        • Контекст слишком большой (\(log.estimatedTokens) ≈ токенов, \(log.messageCount) сообщений)
        • Провайдер перегружен или недоступен
        • Задача слишком объёмная для одного запроса

        **Рекомендации:** начни новый тред, уменьши контекст в настройках треда, или раздели задачу на части.
        """
    }

    // MARK: - Extract Recent File Paths

    func extractRecentFilePaths(from history: [AIMessage]) -> [String] {
        let recentMessages = history.suffix(6)
        var paths: [String] = []
        for message in recentMessages {
            guard let content = message.contentString else { continue }
            let words = content.components(separatedBy: .whitespacesAndNewlines)
            for word in words {
                let clean = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"',()[]{}"))
                if clean.contains("/") && clean.count > 3 && clean.count < 200 { paths.append(clean) }
            }
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }.prefix(5).map { $0 }
    }
}
