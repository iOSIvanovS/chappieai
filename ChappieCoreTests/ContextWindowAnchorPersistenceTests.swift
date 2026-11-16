// ContextWindowAnchorPersistenceTests.swift
// ChappieCoreTests
//
// The orchestrator must remember which message its window started at even when the cache was
// cold, because that turn's request IS the new prefix.
//
// Measured 2026-11-16: a cold turn after a relaunch wrote 78824 tokens (21.43 RUB). Its anchor
// was discarded, so the next turn cut to a different starting message and wrote most of the same
// prefix again instead of reading it. The policy itself was always correct — these tests cover
// the place where its answer was thrown away.

import Foundation
import Testing
@testable import ChappieCore

@Suite("Context window anchor persistence")
struct ContextWindowAnchorPersistenceTests {

    // MARK: - Fixtures

    /// Minimal client: the orchestrator only asks it for a cache profile here.
    private struct StubClient: AIClientProtocol {
        let profile: PromptCacheProfile?

        var promptCacheProfile: PromptCacheProfile? { profile }

        func streamRequestWithTools(
            systemPrompt: String,
            chatHistory: [AIMessage],
            tools: [AITool],
            stallTimeout: TimeInterval,
            onToken: (@Sendable (String) -> Void)?
        ) async throws -> AIStreamResult {
            throw CancellationError()
        }

        func sendRequest(
            systemPrompt: String,
            chatHistory: [AIMessage],
            tools: [AITool]
        ) async throws -> (message: AIMessage, cost: Double?, balance: Double?) {
            throw CancellationError()
        }

        func validateConnection() async throws { throw CancellationError() }
        func validateProvider() async throws { throw CancellationError() }
        func fetchAvailableModels() async -> [String] { [] }
    }

    private func history(_ count: Int) -> [AIMessage] {
        (0..<count).map { AIMessage(role: $0 % 2 == 0 ? "user" : "assistant", content: "m\($0)") }
    }

    private func makeOrchestrator(
        profile: PromptCacheProfile?,
        state: any ContextWindowStateStore,
        threadId: UUID
    ) async -> AIOrchestrator {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chappie-anchor-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let orchestrator = AIOrchestrator(
            aiClient: StubClient(profile: profile),
            toolService: ToolExecutionService(
                fileSystem: FileSystemManager(workspaceURL: root),
                memoryManager: MemoryManager(workspaceURL: root),
                socketPath: "/tmp/chappie-anchor-tests-nonexistent.sock"
            ),
            fileSystem: FileSystemManager(workspaceURL: root),
            memoryManager: MemoryManager(workspaceURL: root),
            config: AppConfig(maxMessagesInContext: 30),
            windowState: state
        )
        // process() takes the thread from MemoryContext; the window builder reads this directly.
        await orchestrator.setThreadForTests(threadId)
        return orchestrator
    }

    // MARK: - The defect

    @Test("A cold turn still records its anchor")
    func coldTurnRecordsAnchor() async {
        let threadId = UUID()
        let state = InMemoryContextWindowStateStore()
        let orchestrator = await makeOrchestrator(
            profile: .anthropicOneHour, state: state, threadId: threadId
        )

        // Nothing was ever sent for this thread, so the cache is cold and the mode is .exact.
        let window = await orchestrator.buildContextWindow(
            from: history(120), currentPrompt: "next", config: AppConfig(maxMessagesInContext: 30)
        )

        #expect(window.count == 31, "30 history messages plus the new prompt")
        #expect(window.first?.contentString == "m90", "a cold turn cuts to the newest `limit`")
        #expect(state.anchorSignature(threadId: threadId) != nil,
                "the window that just went out is the new prefix — its start must be remembered")
    }

    @Test("The turn after a cold turn reads the same prefix instead of re-cutting to a new one")
    func turnAfterColdKeepsThePrefix() async {
        let threadId = UUID()
        let state = InMemoryContextWindowStateStore()
        let orchestrator = await makeOrchestrator(
            profile: .anthropicOneHour, state: state, threadId: threadId
        )
        let config = AppConfig(maxMessagesInContext: 30)

        let cold = await orchestrator.buildContextWindow(
            from: history(120), currentPrompt: "next", config: config
        )

        // The next turn arrives a moment later: the history now holds what the previous request
        // ended with — the prompt "next" and the answer to it — and the mark is warm.
        let grew = history(120) + [
            AIMessage(role: "user", content: "next"),
            AIMessage(role: "assistant", content: "a-next")
        ]
        await orchestrator.markRequestSent()
        let warm = await orchestrator.buildContextWindow(
            from: grew, currentPrompt: "again", config: config
        )

        #expect(warm.first?.contentString == cold.first?.contentString,
                "the window must start where the previous one started")
        #expect(warm.count == 33, "32 messages from the anchored start plus the new prompt")
        let coldContents = cold.compactMap(\.contentString)
        #expect(Array(warm.compactMap(\.contentString).prefix(coldContents.count)) == coldContents,
                "the previous window must still be a prefix: that is the only thing the cache compares")
    }

    @Test("Without the anchor the window slides, which is what these tests exist to prevent")
    func slidingWindowIsWhatWeAvoid() async {
        // Same history, same limits, but nothing remembered: the exact shape of the bug.
        let sliced = ContextWindowPolicy.slice(history(122), limit: 30, mode: .triple)
        #expect(sliced.messages.first?.contentString == "m92",
                "measured: the unanchored window starts two messages later than the previous one")
    }

    // MARK: - What must not change

    @Test("A route without a cache still sends exactly the window")
    func noProfileUsesSlack() async {
        let threadId = UUID()
        let state = InMemoryContextWindowStateStore()
        let orchestrator = await makeOrchestrator(profile: nil, state: state, threadId: threadId)

        let window = await orchestrator.buildContextWindow(
            from: history(120), currentPrompt: "next", config: AppConfig(maxMessagesInContext: 30)
        )

        #expect(window.count == 31)
        #expect(window.first?.contentString == "m90")
    }

    @Test("A long pause keeps the remembered anchor, but drops back to the exact window")
    func coldAfterPauseUsesExactWindow() async {
        let threadId = UUID()
        let state = InMemoryContextWindowStateStore()
        let orchestrator = await makeOrchestrator(
            profile: .anthropicOneHour, state: state, threadId: threadId
        )
        let config = AppConfig(maxMessagesInContext: 30)

        _ = await orchestrator.buildContextWindow(from: history(120), currentPrompt: "a", config: config)

        // Pretend two hours passed: the prefix is gone, so the allowance shrinks to one window.
        state.setLastRequestAt(Date().addingTimeInterval(-7200), threadId: threadId)

        let cold = await orchestrator.buildContextWindow(
            from: history(160), currentPrompt: "b", config: config
        )
        #expect(cold.count == 31, "a cold cache never carries an oversized window")
        #expect(cold.first?.contentString == "m130", "and it cuts to the newest `limit` messages")
        #expect(state.anchorSignature(threadId: threadId) != nil, "the new window is remembered too")
    }

    @Test("Another thread never inherits this thread's anchor")
    func anchorIsPerThread() async {
        let first = UUID()
        let second = UUID()
        let state = InMemoryContextWindowStateStore()
        let orchestrator = await makeOrchestrator(
            profile: .anthropicOneHour, state: state, threadId: first
        )

        _ = await orchestrator.buildContextWindow(
            from: history(120), currentPrompt: "a", config: AppConfig(maxMessagesInContext: 30)
        )
        #expect(state.anchorSignature(threadId: second) == nil)
    }
}
