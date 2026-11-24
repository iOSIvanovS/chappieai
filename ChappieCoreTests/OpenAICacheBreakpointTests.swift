import Testing
import Foundation
@testable import ChappieCore

@Suite("OpenAI cache breakpoints")
struct OpenAICacheBreakpointTests {

    private func client() -> AIClient {
        AIClient(baseURL: "https://example.com/v1/chat/completions", apiKey: "k", modelName: "m", supportsCaching: true)
    }

    private func frame() -> AIMessage {
        ScreenFrame.message(parts: [.imageURL("data:image/jpeg;base64,AAAA")])
    }

    private func marked(_ message: AIMessage) -> Bool {
        guard case .blocks(let blocks)? = message.content else { return false }
        return blocks.contains { $0.cache_control != nil }
    }

    private func history() -> [AIMessage] {
        [
            AIMessage(role: "user", content: "hello"),
            AIMessage(role: "assistant", content: "ok"),
            AIMessage(role: "tool", content: "result", tool_call_id: "c1")
        ]
    }

    @Test("breakpoint lands on the last message before the frame, never on the frame")
    func breakpointBeforeFrame() {
        let result = OpenAICacheBreakpoints.marking(history() + [frame()])
        #expect(result.count == 4)
        #expect(marked(result[2]))
        #expect(!marked(result[0]) && !marked(result[1]))
        #expect(result[3].role == ScreenFrame.role)
        #expect(!marked(result[3]))
    }

    @Test("text is kept intact inside the block")
    func textPreserved() {
        let result = OpenAICacheBreakpoints.marking(history())
        #expect(result[2].contentString == "result")
        #expect(result[2].tool_call_id == "c1")
    }

    @Test("a picture-only tail is skipped, the breakpoint moves one message earlier")
    func skipsUnmarkableTail() {
        let picture = AIMessage(role: "user", multimodalParts: [.imageURL("data:image/png;base64,AAAA")])
        let result = OpenAICacheBreakpoints.marking(history() + [picture])
        #expect(marked(result[2]))
        #expect(!marked(result[3]))
    }

    @Test("empty history is returned unchanged")
    func emptyHistory() {
        #expect(OpenAICacheBreakpoints.marking([]).isEmpty)
        #expect(OpenAICacheBreakpoints.marking([frame()]).count == 1)
    }

    @Test("explicit mode marks the system prompt and one history message, nothing else")
    func explicitModeBuild() {
        let settings = OpenAICacheSettings(placement: .explicit, sendSessionID: false)
        let messages = client().buildMessages(systemPrompt: "sys", chatHistory: history() + [frame()], cacheSettings: settings)
        #expect(messages.count == 5)
        #expect(marked(messages[0]))
        #expect(messages.filter(marked).count == 2)
        #expect(messages.last?.role == "user")
        #expect(!marked(messages.last!))
    }

    @Test("topLevel mode leaves the messages plain")
    func topLevelModeBuild() {
        let settings = OpenAICacheSettings(placement: .topLevel, sendSessionID: false)
        let messages = client().buildMessages(systemPrompt: "sys", chatHistory: history(), cacheSettings: settings)
        #expect(messages.filter(marked).isEmpty)
    }

    @Test("defaults: explicit placement, no session id; stored values override")
    func settingsDefaults() throws {
        let suite = "OpenAICacheSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let fresh = OpenAICacheSettings.resolve(from: defaults)
        #expect(fresh.placement == .explicit)
        #expect(!fresh.sendSessionID)

        defaults.set("topLevel", forKey: OpenAICacheSettings.placementKey)
        defaults.set(true, forKey: OpenAICacheSettings.sessionKey)
        let overridden = OpenAICacheSettings.resolve(from: defaults)
        #expect(overridden.placement == .topLevel)
        #expect(overridden.sendSessionID)

        defaults.set("garbage", forKey: OpenAICacheSettings.placementKey)
        #expect(OpenAICacheSettings.resolve(from: defaults).placement == .explicit)
    }

    @Test("request body carries session_id only when asked, and top-level cache_control only in topLevel")
    func requestBodyFields() throws {
        func json(_ request: AITunnelRequest) throws -> [String: Any] {
            let data = try JSONEncoder().encode(request)
            return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        }
        let plain = try json(AITunnelRequest(model: "m", messages: []))
        #expect(plain["session_id"] == nil)
        #expect(plain["cache_control"] == nil)
        let pinned = try json(AITunnelRequest(model: "m", messages: [], cacheControl: .oneHour, sessionID: "abc"))
        #expect(pinned["session_id"] as? String == "abc")
        #expect(pinned["cache_control"] != nil)
    }
}
