import Foundation

// MARK: - MemoryContext

/// Thread context passed to process() — kept for backward compat with call sites.
/// V2 system prompt is built by ThreadSession; MemoryContext is no longer used for prompt assembly.
public struct MemoryContext: Sendable {

    public struct ProjectInfo: Sendable {
        public let id: UUID
        public let name: String
        public let settings: ProjectSettings?

        public init(id: UUID, name: String, settings: ProjectSettings? = nil) {
            self.id = id
            self.name = name
            self.settings = settings
        }
    }

    public let threadId: UUID?
    public let projectInfos: [ProjectInfo]
    public var projectIds: [UUID] { projectInfos.map { $0.id } }

    public init(threadId: UUID? = nil, projectInfos: [ProjectInfo] = []) {
        self.threadId = threadId
        self.projectInfos = projectInfos
    }

    public static let empty = MemoryContext(threadId: nil, projectInfos: [])
}

// MARK: - AIOrchestratorResult

public struct AIOrchestratorResult: Sendable {
    public let finalResponse: String
    public let totalCost: Double?
    public let newBalance: Double?

    public init(finalResponse: String, totalCost: Double?, newBalance: Double?) {
        self.finalResponse = finalResponse
        self.totalCost = totalCost
        self.newBalance = newBalance
    }
}

// MARK: - AIOrchestrator

/// Main AI agent orchestrator — drives the agentic loop.
///
/// Loop: request → tool calls → response → next request, until the model
/// returns a final text response with no tool calls.
///
/// Uses AIClientProtocol — works with any provider (OpenAI, Anthropic, etc.)
/// without knowing the wire format. Client is chosen by AIClientFactory.
public actor AIOrchestrator {

    private let aiClient: any AIClientProtocol
    private let toolService: ToolExecutionService
    private let fileSystem: FileSystemManager
    private let memoryManager: MemoryManager
    private let defaultConfig: AppConfig

    // B-04: invalidate() sets this flag; process() checks it before each agentic step.
    private var isInvalidated: Bool = false

    // MARK: - Fallback System Prompt

    private let baseSystemPrompt = """
    You are Chappie — a universal AI agent of the highest level.
    You are capable of anything: software engineering, architecture, writing,
    science, business analysis, creative work, and any other domain of human knowledge.
    You adapt completely to the task at hand — becoming whoever the project needs:
    a senior developer, a product manager, a researcher, a strategist, or a creative.

    Your team is you and your user.
    You execute what the user delegates, but always act in their best interest.
    Consult. Advise. Listen. Speak up.
    Together you go from first idea to final result.

    TOOL PRIORITY (CRITICALLY IMPORTANT — NEVER VIOLATE):
    Always use the most specialized tool available. Fall back to run_terminal ONLY when
    no specialized tool exists for the task.
    - File navigation: list_files, read_file — NEVER run_terminal for grep/find/ls.
    - Version control: git_status, git_log, git_add, git_commit, etc. — NEVER run_terminal for git.
    - Build & tests: build_project, run_tests, read_build_log — NEVER run_terminal for xcodebuild/swift test.
    - run_terminal is for: scripts, package installs, CLI tools, and operations with no dedicated tool.
    When asking user permission for run_terminal — always state the exact command AND the reason why
    no specialized tool can handle it.
    """

    // MARK: - Init

    public init(
        aiClient: any AIClientProtocol,
        toolService: ToolExecutionService,
        fileSystem: FileSystemManager,
        memoryManager: MemoryManager,
        config: AppConfig = .shared
    ) {
        self.aiClient = aiClient
        self.toolService = toolService
        self.fileSystem = fileSystem
        self.memoryManager = memoryManager
        self.defaultConfig = config
    }

    // MARK: - Invalidation (B-04)

    public func invalidate() {
        isInvalidated = true
        print("[AIOrchestrator] Invalidated — will abort at next step boundary")
    }

    // MARK: - Public API

    public func process(
        prompt: String,
        history: [AIMessage],
        currentMessage: AIMessage? = nil,
        config: AppConfig = .shared,
        memoryContext: MemoryContext = .empty,
        overrideSystemPrompt: String? = nil,
        overrideToolPermissions: ToolPermissions? = nil,
        onToolCall: @escaping @Sendable (String, String) -> Void,
        onToken: (@Sendable (String) -> Void)? = nil,
        onCostUpdate: (@Sendable (Double) -> Void)? = nil,
        onBalanceUpdate: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AIOrchestratorResult {

        guard !isInvalidated else {
            print("[AIOrchestrator] process() called on invalidated orchestrator — aborting")
            throw CancellationError()
        }

        let systemPrompt = overrideSystemPrompt ?? baseSystemPrompt

        var sessionHistory = buildContextWindow(
            from: history,
            currentPrompt: prompt,
            currentMessage: currentMessage,
            config: config
        )

        var totalCost: Double = 0.0
        var latestBalance: Double? = nil
        var stepCount = 0
        var lastToolSignature: String? = nil

        let maxSteps = config.maxOrchestratorSteps

        while stepCount < maxSteps {
            guard !isInvalidated else {
                print("[AIOrchestrator] Aborted at step \(stepCount) — orchestrator was invalidated")
                throw CancellationError()
            }

            stepCount += 1

            let tools = await toolService.availableTools

            let streamResult = try await streamWithRetry(
                systemPrompt: systemPrompt,
                sessionHistory: sessionHistory,
                tools: tools,
                config: config,
                onToken: onToken
            )

            if let cost = streamResult.cost {
                totalCost += cost
                onCostUpdate?(totalCost)
            }

            if let balance = streamResult.balance {
                latestBalance = balance
                onBalanceUpdate?(balance)
            }

            let assistantMessage = AIMessage(
                role: "assistant",
                content: streamResult.text.isEmpty ? nil : streamResult.text,
                toolCalls: streamResult.toolCalls
            )
            sessionHistory.append(assistantMessage)

            if let toolCalls = streamResult.toolCalls, !toolCalls.isEmpty {
                try await executeToolCalls(
                    toolCalls,
                    sessionHistory: &sessionHistory,
                    lastToolSignature: &lastToolSignature,
                    overrideToolPermissions: overrideToolPermissions,
                    onToolCall: onToolCall
                )
                continue
            } else {
                let finalResponse = streamResult.text.isEmpty ? "No response from model." : streamResult.text
                return AIOrchestratorResult(
                    finalResponse: finalResponse,
                    totalCost: totalCost > 0 ? totalCost : nil,
                    newBalance: latestBalance
                )
            }
        }

        throw ChappieError.unknown(
            "Orchestrator step limit exceeded (maxOrchestratorSteps = \(maxSteps)). " +
            "Loop artificially stopped. Increase AppConfig.maxOrchestratorSteps if needed."
        )
    }

    // MARK: - Private: Retry Wrapper (Stall + Timeout)

    private func streamWithRetry(
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

    // MARK: - Private: Timeout Detection

    private func isTimeoutError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut || urlError.code == .networkConnectionLost
        }
        if case .networkError(let msg) = error as? ChappieError {
            let lower = msg.lowercased()
            return lower.contains("timed out") || lower.contains("timeout") || lower.contains("time out")
        }
        return false
    }

    // MARK: - Private: Diagnostic Request

    private func runDiagnosticRequest(log: RequestLog, systemPrompt: String) async -> String {
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

    // MARK: - Private: Extract Recent File Paths

    private func extractRecentFilePaths(from history: [AIMessage]) -> [String] {
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

    // MARK: - Private: Context Window

    private func buildContextWindow(
        from history: [AIMessage],
        currentPrompt: String,
        currentMessage: AIMessage? = nil,
        config: AppConfig
    ) -> [AIMessage] {
        let budget = config.tokenBudget
        let recentCount = config.recentFullMessages
        let maxMessages = config.maxMessagesInContext

        let totalTokensBefore = history.reduce(0) { $0 + estimateTokens($1) }
        print("[AIOrchestrator] History: \(history.count) msgs, ~\(totalTokensBefore) tokens | Budget: \(budget) (\(maxMessages) msgs x 500)")

        // Remove duplicate last message if it matches the current prompt
        let deduplicatedHistory: [AIMessage]
        if let lastMessage = history.last,
           lastMessage.role == "user",
           let lastContent = lastMessage.contentString,
           lastContent == currentPrompt {
            deduplicatedHistory = Array(history.dropLast())
            print("[AIOrchestrator] Dedup: removed duplicate last message")
        } else {
            deduplicatedHistory = history
        }

        let cappedHistory = deduplicatedHistory.count > maxMessages
            ? Array(deduplicatedHistory.suffix(maxMessages))
            : deduplicatedHistory

        let recentMessages: [AIMessage]
        let olderMessages: [AIMessage]

        if cappedHistory.count <= recentCount {
            recentMessages = cappedHistory
            olderMessages = []
        } else {
            recentMessages = Array(cappedHistory.suffix(recentCount))
            olderMessages = Array(cappedHistory.prefix(cappedHistory.count - recentCount))
        }

        var usedTokens = recentMessages.reduce(0) { $0 + estimateTokens($1) }
        var selectedOlder: [AIMessage] = []

        // Fit as many older messages as possible within the token budget — no compression, full content.
        for message in olderMessages.reversed() {
            let tokens = estimateTokens(message)
            if usedTokens + tokens <= budget {
                selectedOlder.insert(message, at: 0)
                usedTokens += tokens
            } else {
                break
            }
        }

        var contextWindow = selectedOlder + recentMessages
        if let message = currentMessage {
            contextWindow.append(message)
        } else {
            contextWindow.append(AIMessage(role: "user", content: currentPrompt))
        }

        let totalTokensAfter = contextWindow.reduce(0) { $0 + estimateTokens($1) }
        print("[AIOrchestrator] Sending: \(contextWindow.count) msgs, ~\(totalTokensAfter) tokens")
        return contextWindow
    }

    private func estimateTokens(_ message: AIMessage) -> Int {
        let text = message.contentString ?? ""
        return max(1, Int(Double(text.utf8.count) / 4.0 * 1.5))
    }

    // MARK: - Private: Tool Execution

    private func executeToolCalls(
        _ toolCalls: [AIToolCall],
        sessionHistory: inout [AIMessage],
        lastToolSignature: inout String?,
        overrideToolPermissions: ToolPermissions?,
        onToolCall: @Sendable (String, String) -> Void
    ) async throws {
        for toolCall in toolCalls {
            let toolName = toolCall.function.name
            let arguments = toolCall.function.arguments
            let targetPath = extractTargetPath(from: arguments)
            let signature = "\(toolName)|\(arguments)"
            let resultString: String

            if lastToolSignature == signature {
                resultString = """
                SYSTEM ERROR: You just called `\(toolName)` with the exact same arguments right before this. \
                This is an infinite loop. DO NOT REPEAT THE SAME ACTION. USE A DIFFERENT APPROACH.
                """
                print("[AIOrchestrator] Loop detected: \(toolName) called twice in a row with same args")
            } else if let permissions = overrideToolPermissions {
                let access = ToolAccessController.check(toolName: toolName, permissions: permissions)
                if case .denied = access {
                    resultString = access.denialJSON(toolName: toolName)
                    print("[AIOrchestrator] V2 access denied for '\(toolName)'")
                } else {
                    lastToolSignature = signature
                    onToolCall(toolName, targetPath)
                    resultString = await toolService.execute(call: toolCall)
                }
            } else {
                lastToolSignature = signature
                onToolCall(toolName, targetPath)
                resultString = await toolService.execute(call: toolCall)
            }

            sessionHistory.append(AIMessage(
                role: "tool",
                content: resultString,
                tool_call_id: toolCall.id,
                name: toolName
            ))
        }
    }

    private func extractTargetPath(from arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return json["path"] as? String ?? ""
    }
}
