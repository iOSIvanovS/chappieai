import Foundation

// MARK: - MemoryContext

/// Passed to process() for backward compatibility — not used for prompt assembly.
/// System prompt is fully built by ThreadSession via SystemPromptBuilder.
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
    /// Absolute paths to files the AI wants to deliver to the user.
    /// Collected from send_attachment / write_document responses.
    public let outputFiles: [String]

    public init(finalResponse: String, totalCost: Double?, newBalance: Double?, outputFiles: [String] = []) {
        self.finalResponse = finalResponse
        self.totalCost = totalCost
        self.newBalance = newBalance
        self.outputFiles = outputFiles
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

    let aiClient: any AIClientProtocol
    let toolService: ToolExecutionService
    let fileSystem: FileSystemManager
    let memoryManager: MemoryManager
    let defaultConfig: AppConfig
    /// Single retry policy for every model request (HTTP errors, network drops, timeouts, stalls).
    let retryPolicy: RetryPolicy

    // B-04: invalidate() sets this flag; process() checks it before each agentic step.
    var isInvalidated: Bool = false

    // MARK: - Init

    public init(
        aiClient: any AIClientProtocol,
        toolService: ToolExecutionService,
        fileSystem: FileSystemManager,
        memoryManager: MemoryManager,
        config: AppConfig = .shared,
        retryPolicy: RetryPolicy = .standard
    ) {
        self.retryPolicy = retryPolicy
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
        onToolCall: @escaping @Sendable (String, String) -> Void,
        onToken: (@Sendable (String) -> Void)? = nil,
        onCostUpdate: (@Sendable (Double) -> Void)? = nil,
        onBalanceUpdate: (@Sendable (Double) -> Void)? = nil,
        onTerminalOutput: (@Sendable (String) -> Void)? = nil,
        onTerminalStart: (@Sendable (String) -> Void)? = nil,
        onTerminalFinish: (@Sendable () -> Void)? = nil,
        onRetry: (@Sendable (RetryStatus?) -> Void)? = nil
    ) async throws -> AIOrchestratorResult {

        guard !isInvalidated else {
            print("[AIOrchestrator] process() called on invalidated orchestrator — aborting")
            throw CancellationError()
        }

        let systemPrompt = overrideSystemPrompt ?? {
            assertionFailure("[AIOrchestrator] overrideSystemPrompt is nil — caller must always provide a system prompt")
            return ""
        }()

        var sessionHistory = buildContextWindow(
            from: history,
            currentPrompt: prompt,
            currentMessage: currentMessage,
            config: config
        )

        var totalCost: Double = 0.0
        var latestBalance: Double? = nil
        var stepCount = 0
        var loopGuard = LoopGuard()
        var collectedOutputFiles: [String] = []

        // No step cap by design: the loop ends on a final answer, Stop/cancel, or a fatal error.
        // Runaway protection is the repeated-call guard + the Stop button, not a magic number.
        while true {
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
                onToken: onToken,
                onRetry: onRetry
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
                    loopGuard: &loopGuard,
                    collectedOutputFiles: &collectedOutputFiles,
                    onToolCall: onToolCall,
                    onTerminalOutput: onTerminalOutput,
                    onTerminalStart: onTerminalStart,
                    onTerminalFinish: onTerminalFinish
                )
                continue
            } else {
                let finalResponse = streamResult.text.isEmpty ? "No response from model." : streamResult.text
                return AIOrchestratorResult(
                    finalResponse: finalResponse,
                    totalCost: totalCost > 0 ? totalCost : nil,
                    newBalance: latestBalance,
                    outputFiles: collectedOutputFiles
                )
            }
        }
    }
}
