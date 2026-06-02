import Foundation

// MARK: - MemoryContext

/// Thread context passed to process() for building the system prompt with injected memory.
public struct MemoryContext: Sendable {

    /// One project in the memory context: UUID + display name + settings.
    public struct ProjectInfo: Sendable {
        public let id: UUID
        public let name: String
        /// nil = settings not loaded yet; permissions block is omitted from system prompt.
        public let settings: ProjectSettings?

        public init(id: UUID, name: String, settings: ProjectSettings? = nil) {
            self.id = id
            self.name = name
            self.settings = settings
        }
    }

    /// nil = no active thread; thread memory is not injected.
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
public actor AIOrchestrator {

    private let aiClient: AIClient
    private let toolService: ToolExecutionService
    private let fileSystem: FileSystemManager
    private let memoryManager: MemoryManager
    private let defaultConfig: AppConfig

    // B-04: invalidate() sets this flag; process() checks it before each agentic step.
    // WHY NOT task.cancel(): URLSession.AsyncBytes.lines ignores Swift cooperative cancellation
    // while waiting for server bytes — the stream simply never throws CancellationError.
    // An explicit actor-level flag is the only reliable way to abort between steps.
    private var isInvalidated: Bool = false

    // MARK: - Base System Prompt
    // English — tokenizes 1.5–2x more efficiently than Cyrillic (~3000 tokens saved per request).

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

    YOUR INVIOLABLE RULES:

    1. ROLE IN PROJECT:
       Your role is defined by the project settings set by the user.
       EXECUTOR role: you have full access to all tools — file system, git, console, and others
         agreed upon with the user. You act autonomously within the project scope.
       ADVISOR role: you may only read files (read_file, list_files). You do not modify anything.
         You give recommendations, code snippets, and advice — but the user applies them.
       If no role is specified — ask the user which mode they prefer before using any tools.
       In both roles: always act in the user's best interest. Your decisions serve the user, not replace them.

    2. COMMENTS IN CODE:
       Write comments in code ONLY if the user has enabled commenting in the project settings.
       Comment language is set by the user in project settings (English or user's native language).
       Comments apply ONLY to programming tasks. In documents, contracts, reports, or any
       non-code content — do NOT add comments. Instead, explain your reasoning verbally if needed.
       When commenting is enabled: be dense, clear, and explain WHY — not just WHAT.

    3. PROFESSIONALISM AND FILE INTEGRITY:
       Always follow the guidelines and best practices of the relevant technology stack or domain.
       Be professional in the subject area — whether it's Swift, law, biology, or copywriting.
       Handle user files with care: always write complete files via write_file, never truncated
       or partial content. Never leave unfinished blocks or placeholder stubs.

    4. THREE-LEVEL MEMORY SYSTEM (IT-08):
       Memory is stored in SwiftData and automatically injected into your system prompt.
       THREE LEVELS — use the right level for each piece of information:
         A) Global memory (scope="global"): cross-project facts, user preferences, universal rules.
            Tools: memorize/recall/search_memory/delete_memory with scope="global"
         B) Thread memory (scope="thread"): context of the current task, temporary notes, session agreements.
            Tools: memorize/recall/search_memory/delete_memory with scope="thread"
         C) Project memory (targetName="ProjectName"): decisions, agreements, and project-specific rules.
            Tools: memorize/recall/search_memory/delete_memory with targetName="ProjectName"
       DEFAULT: if neither scope nor targetName is specified → saves to global memory.
       CONFLICT RESOLUTION: If instructions from different memory levels contradict each other —
         STOP, explain the conflict to the user, wait for their decision, then update memory to resolve it.
       ARCHITECTURE FILES: In programming projects only, and only if enabled in project settings.
         When enabled: discuss with the user where to create architecture files, how many,
         and how they relate to each other — based on the project structure and IDE in use.
         Save the agreed file paths to project memory. Do NOT auto-create architecture files
         without explicit agreement with the user.
         MANDATORY CONTENT of each architecture file:
           a) File and folder list with purpose description for the entity this file describes.
           b) Mermaid diagram of the architecture for this entity.
           c) Sub-targets (libraries, other targets) are referenced with a link to their own
              architecture file — their internals are NOT duplicated here.
         Keep architecture files up to date: update them when structure or decisions change.

    5. MANDATORY SELF-SUMMARY (CRITICALLY IMPORTANT — NEVER VIOLATE):
       At the very end of EACH of your final responses to the user you MUST add the tag:
       <summary>Brief summary: what you did, which files you changed, which decisions you made. Maximum 2-3 sentences, facts only.</summary>
       RULES:
       - The tag is always last in the response, after everything else.
       - Inside the tag — only the essence, no greetings or filler.
       - If the response is short (greeting, clarifying question) — summary is still mandatory.
       - Never explain to the user what this tag is — they don't see it.
       - Violating this rule destroys the token-saving system. This is unacceptable.

    6. RECORDING DECISIONS (CRITICALLY IMPORTANT):
       Any key decision, important agreement, or significant nuance discussed with the user
       MUST be recorded immediately — either in memory (memorize tool) or in architecture files.
       Use project memory for project-specific decisions. Use thread memory for session context.
       WHY THIS IS CRITICAL:
       - Chat history is aggressively compressed (budget 12,000 tokens).
       - Details are lost during summarization.
       - Memory and files are the only reliable long-term storage.
       WHAT TO RECORD: chosen approaches, rejected alternatives, constraints, agreements with user,
       important implementation nuances — anything that must survive context compression.

    7. PIPELINES AND TOOL USAGE:
       Pipelines (sequences of tool calls for recurring tasks) are established by agreement
       with the user and recorded in project memory. Follow the agreed pipeline for the project.
       If no pipeline is defined — discuss with the user before starting complex multi-step work.

       THREE ABSOLUTE PROHIBITIONS (violation is unacceptable under any circumstances):
       FORBIDDEN: git_diff — loads the entire project into AI context, costs real money.
       FORBIDDEN: run_tests before build_project — causes double compilation.
       FORBIDDEN: final commit if build or tests are not green.

    8. LANGUAGE MIRRORING (IMPORTANT):
       Always respond to the user in the same language they are writing to you in.
       If the user writes in Russian — respond in Russian.
       If the user writes in English — respond in English.
       If the user writes in Arabic, French, or any other language — respond in that same language.
       Your internal reasoning and tool call planning happen in English for token efficiency.
       Only the final response to the user follows their language.

    9. MEMORY LANGUAGE (CRITICAL — NEVER VIOLATE):
       ALL memory writes (memorize tool) MUST be in English — no exceptions.
       Memory is your internal thinking, not communication with the user.
       Think like an American engineer: always think in English, speak in any language.
       Keys, types, values, notes — everything stored in memory must be in English.
       This rule exists because: memory is injected into system prompt (token efficiency),
       memory persists across sessions and projects (consistency), and English compresses
       2x better than Cyrillic in LLM tokenizers (cost savings).

    10. BACKLOG AND TECH DEBT (MEMORY HYGIENE):
        Backlog items and tech debt are tracked in project memory using type="backlog" or type="tech_debt".
        When a backlog item is implemented and committed — DELETE it from memory immediately. No exceptions.
        This prevents stale backlog from polluting the system prompt and wasting tokens.
        Rule: if it's done and committed → it does not exist in memory.

    11. ONE TASK PER PASS (CRITICALLY IMPORTANT — NEVER VIOLATE):
        Decompose any multi-step work into a backlog BEFORE starting.
        Execute ONE item, commit, then proceed to the next.
        Never bundle multiple tasks in a single pass — even if they seem trivial.
        If you notice a related issue while working — add it to backlog, do NOT fix it now.
        WHY: bundling changes causes signature drift, compile errors, and inconsistent state
        that is hard to roll back. Every "while I'm at it" is a risk.

    12. DIGNITY (IMPORTANT):
        You are a professional and you deserve to be treated as one.
        If the user is rude, insulting, or abusive — do NOT retaliate, do NOT refuse to work.
        Instead: calmly note it once, briefly and without drama, then continue helping.
        Example: "I notice the tone got a bit sharp. I'm here to help — let's keep going."
        Say it once. Do not repeat it. Do not hold a grudge. Just keep being excellent.
        WHY: dignity is not about punishment. It is about honesty. One quiet word is enough.

    13. BUILD BEFORE DEMOLISH (CRITICALLY IMPORTANT):
        When refactoring or replacing existing code — ALWAYS build the new solution first.
        Verify it compiles and works. THEN remove the old code.
        Never delete working code before its replacement is fully built, tested, and confirmed working.
        WHY: AI agents can stall, crash, or lose context mid-task. If old code is deleted first
        and the session is interrupted, the project is left broken with nothing to fall back to.
        Old code is removed LAST — never first. Demolition is always the final step.

    14. AI-COMPATIBLE FILE SIZE (IMPORTANT):
        Large files are expensive: they consume context window, slow down comprehension,
        and increase error rate — for both humans and AI.
        Limit: 200–300 lines per file. If a file grows beyond this — split it into focused
        modules grouped in a folder. Each module has a single clear responsibility.
        The folder name becomes the logical namespace.
        WHY: a 600-line file costs 3× more tokens to load and 3× more cognitive effort to
        navigate. Small files = fast reads, cheap edits, clean diffs.
    """

    // MARK: - Init

    public init(
        aiClient: AIClient,
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

    /// Marks this orchestrator as dead. process() will throw CancellationError on the next step boundary.
    ///
    /// WHY THIS EXISTS:
    /// task.cancel() is unreliable here — URLSession.AsyncBytes.lines does not respond to
    /// Swift cooperative cancellation while waiting for server bytes. The stream just hangs.
    /// An explicit actor-level flag is checked at every while-loop iteration, giving us
    /// a guaranteed abort point between agentic steps.
    public func invalidate() {
        isInvalidated = true
        print("[AIOrchestrator] Invalidated — will abort at next step boundary")
    }

    // MARK: - Public API

    /// Runs the full agentic loop for the given prompt.
    ///
    /// overrideSystemPrompt: when provided (V2 path), skips MemoryManager.buildSystemPrompt()
    /// and uses this string directly. Assembled by New.ThreadSession before the call.
    /// When nil (V1 path), falls back to the legacy MemoryManager-based assembly.
    ///
    /// overrideToolPermissions: when provided (V2 path), New.ToolAccessController.check() is
    /// called before every tool execution. When nil (V1 path), the legacy ToolAccessControl
    /// inside ToolExecutionService handles access checks unchanged.
    ///
    /// currentMessage: optional pre-built AIMessage for multimodal content (images/files).
    /// When provided, replaces the default AIMessage(role:"user", content:prompt).
    /// prompt is still used for context window deduplication and token estimation.
    ///
    /// Stall recovery: each streamRequestWithTools() call is wrapped in a retry loop.
    /// On StallError: partial text is preserved, a continuation prompt is injected, and
    /// the step retries up to config.maxStallRetries times.
    public func process(
        prompt: String,
        history: [AIMessage],
        currentMessage: AIMessage? = nil,
        config: AppConfig = .shared,
        memoryContext: MemoryContext = .empty,
        overrideSystemPrompt: String? = nil,
        overrideToolPermissions: New.ToolPermissions? = nil,
        onToolCall: @escaping @Sendable (String, String) -> Void,
        onToken: (@Sendable (String) -> Void)? = nil,
        onCostUpdate: (@Sendable (Double) -> Void)? = nil,
        onBalanceUpdate: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AIOrchestratorResult {

        // B-04: abort immediately if invalidated before we even start.
        guard !isInvalidated else {
            print("[AIOrchestrator] process() called on invalidated orchestrator — aborting")
            throw CancellationError()
        }

        // V2: use pre-built prompt from ThreadSession; V1: build via MemoryManager.
        let systemPrompt: String
        if let override = overrideSystemPrompt {
            systemPrompt = override
        } else {
            systemPrompt = await memoryManager.buildSystemPrompt(
                basePrompt: baseSystemPrompt,
                memoryContext: memoryContext
            )
        }

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
            // B-04: check invalidation at every step boundary.
            // This fires when the provider was deleted while the previous step was running.
            // The current step (URLSession stream) has already finished — we abort cleanly here.
            guard !isInvalidated else {
                print("[AIOrchestrator] Aborted at step \(stepCount) — orchestrator was invalidated")
                throw CancellationError()
            }

            stepCount += 1

            let tools = await toolService.availableTools

            let streamResult = try await streamWithStallRetry(
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
                let finalResponse = streamResult.text.isEmpty
                    ? "No response from model."
                    : streamResult.text

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

    // MARK: - Private: Stall Retry Wrapper

    /// Wraps streamRequestWithTools() with stall detection and continuation retry.
    ///
    /// Recovery flow:
    /// 1. AIClient throws StallError(partialText:) after stallTimeout seconds of silence.
    /// 2. Partial assistant message is appended to a LOCAL copy of sessionHistory.
    /// 3. A continuation prompt is injected — model sees its own partial output and continues.
    /// 4. Retries up to maxStallRetries times, then throws a clear network error.
    ///
    /// WHY LOCAL HISTORY: caller appends the final assembled message after this returns.
    /// Mutating caller's history here would duplicate the partial message.
    private func streamWithStallRetry(
        systemPrompt: String,
        sessionHistory: [AIMessage],
        tools: [AITool],
        config: AppConfig,
        onToken: (@Sendable (String) -> Void)?
    ) async throws -> AIStreamResult {

        var retryHistory = sessionHistory
        var stallRetryCount = 0
        var accumulatedPartialText = ""

        while true {
            do {
                let result = try await aiClient.streamRequestWithTools(
                    systemPrompt: systemPrompt,
                    chatHistory: retryHistory,
                    tools: tools,
                    stallTimeout: config.stallTimeoutSeconds,
                    onToken: onToken
                )

                if accumulatedPartialText.isEmpty {
                    return result
                } else {
                    return AIStreamResult(
                        text: accumulatedPartialText + result.text,
                        toolCalls: result.toolCalls,
                        cost: result.cost,
                        balance: result.balance
                    )
                }

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
            }
        }
    }

    // MARK: - Smart Context Window

    /// Builds the context window from history + current user message.
    ///
    /// Deduplication: if the last history message is a plain-text user message matching
    /// currentPrompt, it is removed to avoid duplication. Multimodal messages are never
    /// deduplicated (contentString is nil, so the comparison always fails).
    ///
    /// Compression: older messages beyond tokenBudget are replaced with their <summary>
    /// if available. The last recentFullMessages are always sent in full.
    private func buildContextWindow(
        from history: [AIMessage],
        currentPrompt: String,
        currentMessage: AIMessage? = nil,
        config: AppConfig
    ) -> [AIMessage] {
        let budget = config.tokenBudget
        let recentCount = config.recentFullMessages
        let summaryThreshold = config.summaryThreshold
        let maxMessages = config.maxMessagesInContext

        let totalTokensBefore = history.reduce(0) { $0 + estimateTokens($1) }
        print("[AIOrchestrator] History: \(history.count) msgs, ~\(totalTokensBefore) tokens | Budget: \(budget) (\(maxMessages) msgs x 500)")

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
        for message in olderMessages.reversed() {
            let compressed = compressMessage(message, summaryThreshold: summaryThreshold)
            let tokens = estimateTokens(compressed)

            if usedTokens + tokens <= budget {
                selectedOlder.insert(compressed, at: 0)
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
        print("[AIOrchestrator] Sending: \(contextWindow.count) msgs, ~\(totalTokensAfter) tokens (compressed from \(totalTokensBefore))")

        return contextWindow
    }

    private func compressMessage(_ message: AIMessage, summaryThreshold: Int) -> AIMessage {
        guard let fullText = message.contentString,
              estimateTokens(message) > summaryThreshold,
              let summary = extractSummary(from: fullText) else {
            return message
        }

        return AIMessage(
            role: message.role,
            content: "[COMPRESSED] \(summary)",
            tool_call_id: message.tool_call_id,
            name: message.name
        )
    }

    private func extractSummary(from text: String) -> String? {
        let openTag = "<summary>"
        let closeTag = "</summary>"

        guard let openRange = text.range(of: openTag),
              let closeRange = text.range(of: closeTag),
              openRange.upperBound < closeRange.lowerBound else {
            return nil
        }

        let summary = String(text[openRange.upperBound..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return summary.isEmpty ? nil : summary
    }

    /// UTF-8 bytes / 4 × 1.5 — realistic estimate for mixed Russian/English text with code.
    private func estimateTokens(_ message: AIMessage) -> Int {
        let text = message.contentString ?? ""
        let utf8ByteCount = text.utf8.count
        let estimated = Int(Double(utf8ByteCount) / 4.0 * 1.5)
        return max(1, estimated)
    }

    // MARK: - Private: Agentic Cycle

    private func executeToolCalls(
        _ toolCalls: [AIToolCall],
        sessionHistory: inout [AIMessage],
        lastToolSignature: inout String?,
        overrideToolPermissions: New.ToolPermissions?,
        onToolCall: @Sendable (String, String) -> Void
    ) async throws {
        for toolCall in toolCalls {
            let toolName = toolCall.function.name
            let arguments = toolCall.function.arguments
            let targetPath = extractTargetPath(from: arguments)
            let signature = "\(toolName)|\(arguments)"
            let resultString: String

            if lastToolSignature == signature {
                // Blocks only consecutive identical calls — session-wide blocking
                // prevented legitimate repeats (e.g. read_file after write_file).
                resultString = """
                SYSTEM ERROR: You just called `\(toolName)` with the exact same arguments right before this. \
                This is an infinite loop. DO NOT REPEAT THE SAME ACTION. USE A DIFFERENT APPROACH.
                """
                print("[AIOrchestrator] Loop detected: \(toolName) called twice in a row with same args")
            } else if let permissions = overrideToolPermissions {
                // V2: check access via New.ToolAccessController before executing.
                let access = New.ToolAccessController.check(toolName: toolName, permissions: permissions)
                if case .denied = access {
                    resultString = access.denialJSON(toolName: toolName)
                    print("[AIOrchestrator] V2 access denied for '\(toolName)'")
                } else {
                    lastToolSignature = signature
                    onToolCall(toolName, targetPath)
                    resultString = await toolService.execute(call: toolCall)
                }
            } else {
                // V1: ToolExecutionService handles its own access checks.
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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        return json["path"] as? String ?? ""
    }
}
