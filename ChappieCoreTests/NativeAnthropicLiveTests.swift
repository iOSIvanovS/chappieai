import Testing
import Foundation
@testable import ChappieCore

// Live check of the native Anthropic route against a real gateway.
//
// Runs only when a token is available; skipped in normal test runs so the suite stays offline and
// deterministic. Two sources, because xcodebuild does not forward shell variables to the test
// runner: $CHAPPIE_LIVE_ROUTERAI_TOKEN, or the key file at LiveTokenPath. Delete the file (or
// unset the variable) to turn the suite off.
enum LiveGateway {
    static let tokenPath = "/tmp/.chappie_live_token"
    static var token: String? {
        if let env = ProcessInfo.processInfo.environment["CHAPPIE_LIVE_ROUTERAI_TOKEN"],
           !env.isEmpty { return env }
        guard let raw = try? String(contentsOfFile: tokenPath, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@Suite("Live: native Anthropic route", .enabled(if: LiveGateway.token != nil))
struct NativeAnthropicLiveTests {

    private var token: String { LiveGateway.token ?? "" }

    private func provider() -> AIProvider {
        AIProvider(name: "RouterAI", baseURL: "https://routerai.ru", catalogId: "routerai",
                   providerProtocol: .openai)
    }

    private var tools: [AITool] {
        [AITool(function: AIFunctionDefinition(
            name: "run_terminal",
            description: "Execute a shell command.",
            parameters: AIToolParameters(
                type: "object",
                properties: ["command": AIToolProperty(type: "string", description: "Command")],
                required: ["command"]
            )
        ))]
    }

    private func stream(_ client: any AIClientProtocol, system: String, history: [AIMessage]) async throws -> AIStreamResult {
        try await client.streamRequestWithTools(
            systemPrompt: system,
            chatHistory: history,
            tools: tools,
            stallTimeout: 90,
            onToken: nil
        )
    }

    @Test("Route matches Claude models only")
    func routeMatching() {
        let route = BuiltInProviders.find(id: "routerai")?.nativeAnthropic
        #expect(route != nil)
        #expect(route?.handles(modelId: "anthropic/claude-sonnet-5.5") == true)
        #expect(route?.handles(modelId: "openai/gpt-5") == false)
        #expect(route?.messagesPath == "/api/v1/messages")
        #expect(route?.maxTokens == 32000)
    }

    @Test("Factory sends Claude over native and other models over OpenAI")
    func factoryRouting() {
        let p = provider()
        let claude = AIModel(id: "anthropic/claude-sonnet-5.5", name: "sonnet")
        let gpt = AIModel(id: "openai/gpt-5", name: "gpt")
        #expect(AIClientFactory.make(for: p, apiKey: "k", model: claude) is AnthropicClient)
        #expect(AIClientFactory.make(for: p, apiKey: "k", model: gpt) is AIClient)
    }

    @Test("Live: tool call, tool_result round trip, parallel results, cost")
    func liveTurn() async throws {
        let client = AIClientFactory.make(
            for: provider(), apiKey: token,
            model: AIModel(id: "anthropic/claude-sonnet-5.5", name: "sonnet")
        )
        let system = "You are a helpful agent. " + String(repeating: "Filler for cache. ", count: 900)
        var history = [AIMessage(role: "user", content: "Run exactly: ls -la. Use the tool. Do not explain.")]

        let first = try await stream(client, system: system, history: history)
        let call = try #require(first.toolCalls?.first, "no structured tool call returned")
        #expect(call.function.name == "run_terminal")
        print("LIVE turn1: tool=\(call.function.name) cost=\(String(describing: first.cost)) balance=\(String(describing: first.balance))")

        history.append(AIMessage(role: "assistant", content: first.text.isEmpty ? nil : first.text,
                                 toolCalls: first.toolCalls))
        history.append(AIMessage(role: "tool", content: "total 0\ndrwxr-xr-x 2 user staff 64 .",
                                 tool_call_id: call.id))
        history.append(AIMessage(role: "user", content: "How many entries did you see? One sentence."))

        let second = try await stream(client, system: system, history: history)
        #expect(!second.text.isEmpty)
        print("LIVE turn2: text=\(second.text.prefix(120)) cost=\(String(describing: second.cost))")

        let parallel = [
            AIMessage(role: "user", content: "Do two things."),
            AIMessage(role: "assistant", content: nil, toolCalls: [
                AIToolCall(id: "toolu_A1", type: "function",
                           function: AIToolCallFunction(name: "run_terminal", arguments: #"{"command":"ls"}"#)),
                AIToolCall(id: "toolu_B2", type: "function",
                           function: AIToolCallFunction(name: "run_terminal", arguments: #"{"command":"pwd"}"#))
            ]),
            AIMessage(role: "tool", content: "file1", tool_call_id: "toolu_A1"),
            AIMessage(role: "tool", content: "/tmp", tool_call_id: "toolu_B2"),
            AIMessage(role: "user", content: "Repeat the two outputs you got, comma separated.")
        ]
        let third = try await stream(client, system: "You are a helpful agent.", history: parallel)
        print("LIVE turn3 (parallel tool results): \(third.text.prefix(160))")
        #expect(!third.text.isEmpty)
    }
}
