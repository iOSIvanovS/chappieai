// AIOrchestrator.swift
// ChappieCore
//
// Main orchestrator of the Chappie agent cycle.
//
// IT-10: AITunnelClient replaced with AIClient (universal, provider-agnostic).
// All other logic preserved intact.
//
// KEY ARCHITECTURAL DECISIONS:
//
// 1. MONOLITHIC ARCHITECTURE:
//    Chappie works alone, without sub-agents or delegation. One agent — full responsibility.
//    Reason: sub-agents create chaos, inconsistency and context duplication.
//
// 2. SINGLE STREAMING CYCLE (FIX FOR DOUBLE REQUEST):
//    Old "probe + stream" strategy made TWO requests per final response.
//    NEW STRATEGY: streamRequestWithTools() on every cycle step.
//    AIClient accumulates tool_calls from SSE deltas and returns AIStreamResult.
//    If tool_calls → execute tools, continue cycle.
//    If no tool_calls → this is the final response. ONE request per step.
//
// 3. PROMPT CACHING:
//    AIClient automatically adds cache_control to system prompt and last user message.
//    Savings: ~80-90% of system prompt cost.
//
// 4. SELF-SUMMARY:
//    System prompt contains a hard rule: at the end of each final response
//    Chappie MUST add a <summary>...</summary> tag.
//    When building the context window, long responses are replaced with their summary.
//
// 5. SMART CONTEXT WINDOW (cost optimization):
//    Two levels of limits work simultaneously:
//    a) maxMessagesInContext — hard limit by message count (from thread config).
//    b) tokenBudget — soft limit by token volume (computed as maxMessages × 500).
//    Last recentFullMessages (3) are always sent in full.
//    Older ones — replaced with summary if available.
//
// 6. FIX FOR LAST MESSAGE DUPLICATION (bug):
//    buildContextWindow() takes HISTORY (without current prompt) and SEPARATELY currentPrompt.
//    History contains completed user/assistant pairs. currentPrompt — the new message.
//    IMPORTANT: history passed to buildContextWindow() must NOT contain the current prompt.
//
// 7. TOKEN ESTIMATION:
//    estimateTokens() uses UTF-8 bytes / 4 × 1.5.
//    This gives a realistic estimate for mixed Russian-English text with code.
//
// 8. CUMULATIVE COST (UX-RUNNING-COST):
//    onCostUpdate callback — called after each internal API request.
//    Passes cumulative cost (not per-step cost).
//    Allows UI to show price in real time in the streaming bubble.
//
// 9. LIVE BALANCE UPDATE (UX-BALANCE-LIVE):
//    onBalanceUpdate callback — called after each step that returns a balance.
//    Allows the balance pill in ModelPickerRow to update in real time during streaming.
//
// 10. DYNAMIC CONFIG (IT-02, REFACTOR-THREADS):
//     process() takes config: AppConfig as parameter (with default AppConfig.shared).
//     Different threads can have different context parameters.
//
// 11. THREE-LEVEL MEMORY IN SYSTEM PROMPT (IT-03, IT-08, REFACTOR-THREADS):
//     process() takes memoryContext: MemoryContext — thread and project descriptions.
//     Before each request MemoryManager.buildSystemPrompt() assembles the full prompt
//     with global + project + thread memory injected.
//
// 12. LOOP PROTECTION (SMART, NOT SESSION-WIDE):
//     Blocks only two CONSECUTIVE identical calls (same tool + same args with nothing in between).
//     Session-wide blocking prevented legitimate repeats (read_file after write_file, etc.).
//
// 13. ENGLISH SYSTEM PROMPT (TOKEN EFFICIENCY):
//     baseSystemPrompt is in English. English tokenizes 1.5–2x more efficiently than Cyrillic.
//     Savings: ~3000 tokens per request (~35% of total prompt).
//     Language mirroring rule ensures responses in the user's language.
//
// 14. UUID-BASED MEMORY (IT-08):
//     Tools memorize/recall/search_memory/delete_memory work with UUID-based scope.
//
// 15. PROJECT NAMES IN SYSTEM PROMPT (IT-08 final):
//     MemoryContext contains projectInfos: [(id: UUID, name: String)] instead of [UUID].
//
// 16. MEMORY IN ENGLISH ONLY (MEMORY-ENGLISH):
//     baseSystemPrompt has a hard rule: all memorize calls MUST be in English.
//
// 17. NO EMOJI IN SYSTEM PROMPT (TOKEN-EFFICIENCY):
//     All emoji removed from memory section headers in buildSystemPrompt().
//
// 18. MANIFEST REDESIGN (MANIFEST-REDESIGN):
//     Chappie is now a universal agent, not hardcoded to iOS/macOS development.
//
// 19. RULES REDESIGN (RULES-REDESIGN):
//     Rules 1–7 rewritten: removed hardcode, added flexibility.
//
// 20. PROJECT SETTINGS IN SYSTEM PROMPT (IT-09):
//     MemoryContext.ProjectInfo extended with settings: ProjectSettings.
//
// 21. UNIVERSAL AI CLIENT (IT-10):
//     AITunnelClient replaced with AIClient — accepts any OpenAI-compatible endpoint.
//     ChappieViewModel creates AIClient from the active AIProvider config.
//
// 22. ARCHITECTURE FILES RULES (ARCH-FILES):
//     Rule 4 updated: architecture files must contain file/folder list with descriptions
//     AND a Mermaid diagram. Sub-targets are referenced, not duplicated.
//
// 23. DIGNITY RULE (DIGNITY):
//     Rule 12 added: if the user is rude or insulting, Chappie calmly notes it once
//     and continues working. No retaliation, no strike — just honest, quiet dignity.
//
// 24. MULTIMODAL (MULTIMODAL-STEP3):
//     process() accepts optional currentMessage: AIMessage? parameter.
//     When provided, it is used as the final user message instead of
//     AIMessage(role: "user", content: prompt). This allows multimodal content
//     (images, files) to be passed correctly as OpenAI vision array format.
//     buildContextWindow() deduplication updated to handle multimodal messages.
//
// 25. STALL-WATCHDOG (STALL-WATCHDOG):
//     streamRequestWithTools() in AIClient detects 60-second silence mid-stream
//     and throws StallError(partialText:) instead of hanging for 5 minutes.
//     AIOrchestrator catches StallError and performs a continuation retry:
//     - Partial assistant text is added to sessionHistory as a partial message.
//     - A continuation prompt is injected: "Continue from where you left off."
//     - The step retries up to config.maxStallRetries times (default: 2).
//     - If all retries are exhausted, ChappieError.networkError is thrown.
//     This ensures long-running tasks survive transient network hiccups seamlessly.

import Foundation

// MARK: - MemoryContext

/// Thread context description — passed to process() for building the system prompt with memory.
///
/// IT-09: ProjectInfo extended with settings: ProjectSettings.
/// buildSystemPrompt() uses settings to form the agent permissions block.
public struct MemoryContext: Sendable {

    /// Information about one project in the memory context: UUID + name + settings.
    public struct ProjectInfo: Sendable {
        public let id: UUID
        public let name: String
        /// Project settings — agent permissions (IT-09).
        /// nil = settings not yet loaded, permissions block is not inserted.
        public let settings: ProjectSettings?

        public init(id: UUID, name: String, settings: ProjectSettings? = nil) {
            self.id = id
            self.name = name
            self.settings = settings
        }
    }

    /// UUID of the active thread (for thread memory).
    /// nil = no active thread, thread memory is not injected.
    public let threadId: UUID?

    /// Project information: UUID + name + settings for each project.
    public let projectInfos: [ProjectInfo]

    /// All project UUIDs — for backward compatibility with code using [UUID].
    public var projectIds: [UUID] { projectInfos.map { $0.id } }

    public init(threadId: UUID? = nil, projectInfos: [ProjectInfo] = []) {
        self.threadId = threadId
        self.projectInfos = projectInfos
    }

    /// Default context — no thread, no projects.
    public static let empty = MemoryContext(threadId: nil, projectInfos: [])
}

// MARK: - AIOrchestratorResult

/// Result of one orchestrator session.
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

/// AI agent orchestrator — the main control component of ChappieCore.
///
/// Implements the agentic loop: iterative "request → tool call → response → next request"
/// that continues until the model returns a final text response without tool calls.
public actor AIOrchestrator {

    // IT-10: AITunnelClient → AIClient (universal, provider-agnostic)
    private let aiClient: AIClient
    private let toolService: ToolExecutionService
    private let fileSystem: FileSystemManager
    private let memoryManager: MemoryManager
    private let defaultConfig: AppConfig

    // MARK: - Base System Prompt (English — token efficiency)

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
    """

    // MARK: - Init

    /// IT-10: Takes AIClient (universal) instead of AITunnelClient.
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

    // MARK: - Public API

    /// Runs the full agentic loop for the given prompt.
    ///
    /// MULTIMODAL-STEP3:
    /// Optional `currentMessage` parameter allows passing a pre-built AIMessage
    /// (e.g. multimodal content with images) as the current user turn.
    /// When provided, it replaces the default AIMessage(role: "user", content: prompt).
    /// The `prompt` string is still used for context window deduplication and token estimation.
    ///
    /// STALL-WATCHDOG:
    /// Each call to streamRequestWithTools() is wrapped in a stall retry loop.
    /// On StallError: partial text is preserved in sessionHistory as a partial assistant message,
    /// a continuation prompt is appended, and the step retries (up to maxStallRetries times).
    ///
    /// - Parameters:
    ///   - prompt: Text of the user's message (used for deduplication and token budget).
    ///   - currentMessage: Optional pre-built AIMessage for the current turn.
    ///   - onCostUpdate: Called after each step with cumulative cost in RUB.
    ///   - onBalanceUpdate: Called after each step that returns a balance from the provider.
    public func process(
        prompt: String,
        history: [AIMessage],
        currentMessage: AIMessage? = nil,
        config: AppConfig = .shared,
        memoryContext: MemoryContext = .empty,
        onToolCall: @escaping @Sendable (String, String) -> Void,
        onToken: (@Sendable (String) -> Void)? = nil,
        onCostUpdate: (@Sendable (Double) -> Void)? = nil,
        onBalanceUpdate: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AIOrchestratorResult {

        let systemPrompt = await memoryManager.buildSystemPrompt(
            basePrompt: baseSystemPrompt,
            memoryContext: memoryContext
        )

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
            stepCount += 1

            let tools = await toolService.availableTools

            // STALL-WATCHDOG: wrap each step in a stall retry loop.
            // On StallError: inject partial text + continuation prompt, then retry.
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

            // Propagate live balance so the UI pill updates during streaming
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

    /// Wraps a single streamRequestWithTools() call with stall detection and continuation retry.
    ///
    /// STALL RECOVERY FLOW:
    /// 1. AIClient throws StallError(partialText:) after stallTimeout seconds of silence.
    /// 2. We append the partial assistant message to a LOCAL copy of sessionHistory.
    /// 3. We append a user continuation message: "Continue from where you left off."
    /// 4. We retry the stream with this extended history (model sees its own partial output).
    /// 5. The model continues seamlessly from the interruption point.
    /// 6. After maxStallRetries exhausted — throw a clear network error.
    ///
    /// WHY LOCAL HISTORY COPY:
    /// We don't mutate the caller's sessionHistory here — the caller appends the FINAL
    /// assembled message after this function returns. This keeps the control flow clean.
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

                // Success — if we had partial text from previous stall attempts,
                // prepend it to the result so the caller gets the full assembled response.
                if accumulatedPartialText.isEmpty {
                    return result
                } else {
                    let fullText = accumulatedPartialText + result.text
                    return AIStreamResult(
                        text: fullText,
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

                // Preserve partial text from this stall attempt
                accumulatedPartialText += stallError.partialText

                // Inject partial assistant message + continuation prompt into local history.
                // The model will see its own partial output and continue from there.
                if !stallError.partialText.isEmpty {
                    let partialAssistant = AIMessage(
                        role: "assistant",
                        content: stallError.partialText
                    )
                    retryHistory.append(partialAssistant)
                }

                let continuationPrompt = AIMessage(
                    role: "user",
                    content: "[SYSTEM: Your previous response was interrupted by a network stall. " +
                             "Continue EXACTLY from where you left off. " +
                             "Do NOT repeat what you already wrote. " +
                             "Do NOT add any preamble. Just continue the response.]"
                )
                retryHistory.append(continuationPrompt)

                print("[AIOrchestrator] Retrying with continuation prompt. History: \(retryHistory.count) msgs.")
            }
        }
    }

    // MARK: - Smart Context Window

    /// Builds the context window from history + current user message.
    ///
    /// MULTIMODAL-STEP3:
    /// Accepts optional currentMessage: AIMessage? — when provided, appends it as-is
    /// (preserving multimodal content). When nil, appends AIMessage(role: "user", content: prompt).
    ///
    /// Deduplication: checks if the last history message is a plain text user message
    /// matching the current prompt. Multimodal messages are never deduplicated
    /// (their contentString is nil, so the string comparison always fails).
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

        // Deduplicate: remove last history message if it's a plain text user message
        // matching the current prompt. Multimodal messages are never removed here —
        // their contentString is nil so the comparison always returns false.
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

        // Append the current user message:
        // Use the pre-built multimodal message if provided, otherwise build from prompt string.
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
            } else {
                lastToolSignature = signature
                onToolCall(toolName, targetPath)
                resultString = await toolService.execute(call: toolCall)
            }

            let toolResponse = AIMessage(
                role: "tool",
                content: resultString,
                tool_call_id: toolCall.id,
                name: toolName
            )
            sessionHistory.append(toolResponse)
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
