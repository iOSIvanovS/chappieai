// SentPrefixTests.swift
// ChappieCoreTests
//
// A changed system prompt or tool list invalidates the provider's whole prefix, so the wide
// allowance must not be spent on a request that will be written from scratch anyway.
//
// These tests cover the comparison itself and then the orchestrator's decision on top of it. The
// comparison is the part that must not be fooled: a "kept" answer that is wrong costs a full
// prefix write, and a "changed" answer that is wrong costs a needlessly short window.

import Foundation
import Testing
@testable import ChappieCore

@Suite("Sent prefix fingerprint")
struct SentPrefixTests {

    // MARK: - Fixtures

    private func message(_ text: String, role: String = "user") -> AIMessage {
        AIMessage(role: role, content: text)
    }

    private func tool(_ name: String, description: String = "does something") -> AITool {
        AITool(
            type: "function",
            function: AIFunctionDefinition(
                name: name,
                description: description,
                parameters: AIToolParameters(
                    type: "object",
                    properties: ["project": AIToolProperty(type: "string", description: "where")],
                    required: ["project"]
                )
            )
        )
    }

    // MARK: - The comparison

    @Test("Identical tools, system prompt and messages are reported as kept")
    func identicalIsKept() {
        let tools = [tool("read_file"), tool("write_file")]
        let messages = [message("a"), message("b")]

        let stored = PrefixFingerprint.make(tools: tools, system: "sys", messages: messages)
        let verdict = PrefixFingerprint.verdict(
            stored: stored, tools: tools, system: "sys", messages: messages
        )

        #expect(verdict == .kept)
    }

    @Test("Appending messages does not disturb the prefix that was already sent")
    func appendingKeepsTheVerdict() {
        // The ordinary case between two turns: the stored request is a prefix of the new one.
        let tools = [tool("read_file")]
        let sent = [message("a"), message("b"), message("c")]

        let stored = PrefixFingerprint.make(tools: tools, system: "sys", messages: sent)
        let verdict = PrefixFingerprint.verdict(
            stored: stored,
            tools: tools,
            system: "sys",
            messages: sent + [message("answer", role: "assistant"), message("next")]
        )

        #expect(verdict == .kept)
    }

    @Test("A changed system prompt invalidates everything after its first byte")
    func systemChangeIsHeadChanged() {
        let tools = [tool("read_file")]
        let messages = [message("a")]

        let stored = PrefixFingerprint.make(tools: tools, system: "sys one", messages: messages)
        let verdict = PrefixFingerprint.verdict(
            stored: stored, tools: tools, system: "sys two", messages: messages
        )

        #expect(verdict == .headChanged)
    }

    @Test("A changed tool description invalidates the prefix just as surely")
    func toolDescriptionChangeIsHeadChanged() {
        let messages = [message("a")]
        let before = [tool("read_file", description: "reads a file")]
        let after = [tool("read_file", description: "reads a file [UNAVAILABLE]")]

        let stored = PrefixFingerprint.make(tools: before, system: "sys", messages: messages)
        let verdict = PrefixFingerprint.verdict(
            stored: stored, tools: after, system: "sys", messages: messages
        )

        #expect(verdict == .headChanged)
    }

    @Test("A reordered tool list counts as a change: the provider compares bytes, not meaning")
    func toolOrderMatters() {
        let messages = [message("a")]
        let one = [tool("a"), tool("b")]
        let two = [tool("b"), tool("a")]

        let stored = PrefixFingerprint.make(tools: one, system: "sys", messages: messages)
        #expect(PrefixFingerprint.verdict(stored: stored, tools: two, system: "sys", messages: messages)
                == .headChanged)
    }

    @Test("A window that slid is reported as a message change even though the head matches")
    func slidWindowIsMessagesChanged() {
        let tools = [tool("read_file")]
        let sent = [message("a"), message("b"), message("c")]

        let stored = PrefixFingerprint.make(tools: tools, system: "sys", messages: sent)
        // Same count, different content: exactly what an unanchored window does.
        let slid = [message("b"), message("c"), message("d")]
        let verdict = PrefixFingerprint.verdict(
            stored: stored, tools: tools, system: "sys", messages: slid
        )

        #expect(verdict == .messagesChanged)
    }

    @Test("A history shorter than what was sent cannot be compared and is reported as changed")
    func shorterHistoryIsMessagesChanged() {
        let tools = [tool("read_file")]
        let stored = PrefixFingerprint.make(
            tools: tools, system: "sys", messages: [message("a"), message("b"), message("c")]
        )
        let verdict = PrefixFingerprint.verdict(
            stored: stored, tools: tools, system: "sys", messages: [message("a")]
        )

        #expect(verdict == .messagesChanged)
    }

    @Test("Nothing recorded is reported as unknown, not as kept")
    func noRecordIsUnknown() {
        let verdict = PrefixFingerprint.verdict(
            stored: nil, tools: [tool("a")], system: "s", messages: [message("m")]
        )
        #expect(verdict == .unknown)
        #expect(verdict.label == "unknown")
    }

    // MARK: - Storage form

    @Test("The stored form survives a round trip")
    func rawValueRoundTrip() {
        let original = SentPrefix(headHash: 0x0123_4567_89ab_cdef, prefixHash: 0xfedc_ba98_7654_3210, messageCount: 42)
        #expect(SentPrefix(rawValue: original.rawValue) == original)
    }

    @Test("A corrupt or older stored form is 'nothing known', never a wrong answer")
    func rawValueRejectsGarbage() {
        #expect(SentPrefix(rawValue: "") == nil)
        #expect(SentPrefix(rawValue: "abc") == nil)
        #expect(SentPrefix(rawValue: "abc|def") == nil)
        #expect(SentPrefix(rawValue: "zzzz|0000|1") == nil)
        #expect(SentPrefix(rawValue: "0000|0000|-1") == nil)
    }

    // MARK: - Determinism

    @Test("The same parts hash the same in a rebuilt encoding")
    func encodingIsStable() {
        // Tool schemas hang off dictionaries, whose encoder order is seeded per process. A hash
        // taken over unsorted bytes would differ after a relaunch even with identical content.
        let tools = [tool("write_file"), tool("read_file"), tool("patch_file")]

        let first = PrefixFingerprint.headHash(tools: tools, system: "sys")
        let second = PrefixFingerprint.headHash(tools: tools, system: "sys")

        #expect(first == second)
    }

    @Test("Two different pairs of parts never produce the same bytes by concatenation")
    func noBoundaryCollision() {
        // Without a length prefix, tools ending in "a" plus system "b" would equal tools "ab".
        let left = PrefixFingerprint.make(tools: [], system: "ab", messages: [])
        let right = PrefixFingerprint.make(tools: [], system: "a", messages: [message("b")])
        #expect(left.prefixHash != right.prefixHash)
    }
}

// MARK: - The orchestrator's decision

@Suite("Context window prefix check")
struct ContextWindowPrefixTests {

    private struct StubClient: AIClientProtocol {
        let profile: PromptCacheProfile?

        var promptCacheProfile: PromptCacheProfile? { profile }

        func streamRequestWithTools(
            systemPrompt: String, chatHistory: [AIMessage], tools: [AITool],
            stallTimeout: TimeInterval, onToken: (@Sendable (String) -> Void)?
        ) async throws -> AIStreamResult { throw CancellationError() }

        func sendRequest(
            systemPrompt: String, chatHistory: [AIMessage], tools: [AITool]
        ) async throws -> (message: AIMessage, cost: Double?, balance: Double?) { throw CancellationError() }

        func validateConnection() async throws { throw CancellationError() }
        func validateProvider() async throws { throw CancellationError() }
        func fetchAvailableModels() async -> [String] { [] }
    }

    private func history(_ count: Int) -> [AIMessage] {
        (0..<count).map { AIMessage(role: $0 % 2 == 0 ? "user" : "assistant", content: "m\($0)") }
    }

    private func makeOrchestrator(
        state: any ContextWindowStateStore,
        threadId: UUID
    ) async -> AIOrchestrator {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chappie-prefix-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let orchestrator = AIOrchestrator(
            aiClient: StubClient(profile: .anthropicOneHour),
            toolService: ToolExecutionService(
                fileSystem: FileSystemManager(workspaceURL: root),
                memoryManager: MemoryManager(workspaceURL: root),
                socketPath: "/tmp/chappie-prefix-tests-nonexistent.sock"
            ),
            fileSystem: FileSystemManager(workspaceURL: root),
            memoryManager: MemoryManager(workspaceURL: root),
            config: AppConfig(maxMessagesInContext: 30),
            windowState: state
        )
        await orchestrator.setThreadForTests(threadId)
        return orchestrator
    }

    private func tool(_ name: String) -> AITool {
        AITool(
            type: "function",
            function: AIFunctionDefinition(
                name: name,
                description: "[AVAILABLE] \(name)",
                parameters: AIToolParameters(type: "object", properties: [:], required: [])
            )
        )
    }

    @Test("A changed system prompt cuts the window to `limit` instead of sending an oversized one")
    func changedSystemPromptForcesExact() async {
        let threadId = UUID()
        let state = InMemoryContextWindowStateStore()
        let orchestrator = await makeOrchestrator(state: state, threadId: threadId)
        let config = AppConfig(maxMessagesInContext: 30)
        let tools = [tool("read_file")]

        // Warm the cache so the wide allowance would normally apply.
        _ = await orchestrator.buildContextWindow(
            from: history(120), currentPrompt: "a", config: config,
            systemPrompt: "SYS ONE", tools: tools
        )
        await orchestrator.markRequestSent()

        // The system prompt changed between turns: memory was edited, or a project was added.
        let window = await orchestrator.buildContextWindow(
            from: history(160), currentPrompt: "b", config: config,
            systemPrompt: "SYS TWO", tools: tools
        )

        #expect(window.count == 31, "a rewrite is coming, so carry no more than the window")
        #expect(window.first?.contentString == "m130")
    }

    @Test("A changed tool list does the same")
    func changedToolsForceExact() async {
        let threadId = UUID()
        let state = InMemoryContextWindowStateStore()
        let orchestrator = await makeOrchestrator(state: state, threadId: threadId)
        let config = AppConfig(maxMessagesInContext: 30)

        _ = await orchestrator.buildContextWindow(
            from: history(120), currentPrompt: "a", config: config,
            systemPrompt: "sys", tools: [tool("read_file")]
        )
        await orchestrator.markRequestSent()

        let window = await orchestrator.buildContextWindow(
            from: history(160), currentPrompt: "b", config: config,
            systemPrompt: "sys", tools: [tool("read_file"), tool("write_file")]
        )

        #expect(window.count == 31)
        #expect(window.first?.contentString == "m130")
    }

    @Test("An unchanged head still gets the wide allowance, and the window stands still")
    func unchangedHeadKeepsWideWindow() async {
        let threadId = UUID()
        let state = InMemoryContextWindowStateStore()
        let orchestrator = await makeOrchestrator(state: state, threadId: threadId)
        let config = AppConfig(maxMessagesInContext: 30)
        let tools = [tool("read_file")]

        let first = await orchestrator.buildContextWindow(
            from: history(120), currentPrompt: "a", config: config,
            systemPrompt: "sys", tools: tools
        )
        await orchestrator.markRequestSent()

        let second = await orchestrator.buildContextWindow(
            from: history(120) + [AIMessage(role: "user", content: "a"),
                                  AIMessage(role: "assistant", content: "answer")],
            currentPrompt: "b", config: config, systemPrompt: "sys", tools: tools
        )

        #expect(second.first?.contentString == first.first?.contentString,
                "the window must start where the previous one started")
        // 30 window messages + the previous prompt "a" + its answer + the new prompt "b".
        // No re-cut: the previous request must still be a prefix of this one.
        #expect(second.count == 33, "the previous window grew by the answer and the new prompt")
    }

    @Test("The first turn of a process reports an unknown prefix and sends the exact window")
    func firstTurnIsUnknown() async {
        let threadId = UUID()
        let state = InMemoryContextWindowStateStore()
        let orchestrator = await makeOrchestrator(state: state, threadId: threadId)

        let window = await orchestrator.buildContextWindow(
            from: history(120), currentPrompt: "a", config: AppConfig(maxMessagesInContext: 30),
            systemPrompt: "sys", tools: [tool("read_file")]
        )

        #expect(window.count == 31)
    }

    @Test("Each turn records what it sent, so the next one has something to compare")
    func recordsThePrefix() async {
        let threadId = UUID()
        let state = InMemoryContextWindowStateStore()
        let orchestrator = await makeOrchestrator(state: state, threadId: threadId)

        #expect(state.sentPrefix(threadId: threadId) == nil)

        _ = await orchestrator.buildContextWindow(
            from: history(120), currentPrompt: "a", config: AppConfig(maxMessagesInContext: 30),
            systemPrompt: "sys", tools: [tool("read_file")]
        )

        let stored = state.sentPrefix(threadId: threadId)
        #expect(stored != nil)
        // The history part only: the new prompt is appended after the window is decided.
        #expect(stored?.messageCount == 30)
    }
}
