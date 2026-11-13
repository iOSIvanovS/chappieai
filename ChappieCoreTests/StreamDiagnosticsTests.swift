import Testing
import Foundation
@testable import ChappieCore

@Suite("StreamDiagnostics")
struct StreamDiagnosticsTests {

    private func chunk(_ json: String) throws -> AIStreamChunk {
        try JSONDecoder().decode(AIStreamChunk.self, from: Data(json.utf8))
    }

    @Test("records finish_reason, upstream model and provider from chunks")
    func recordsMetadata() throws {
        var d = StreamDiagnostics()
        d.record(try chunk(#"{"model":"anthropic/claude-sonnet-5.5","provider":"Anthropic","choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}"#))
        d.record(try chunk(#"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#))
        #expect(d.chunks == 2)
        #expect(d.finishReason == "tool_calls")
        #expect(d.upstreamModel == "anthropic/claude-sonnet-5.5")
        #expect(d.upstreamProvider == "Anthropic")
    }

    @Test("a wrong-typed model field does not cost the whole chunk")
    func wrongTypedMetadataIsTolerated() throws {
        let c = try chunk(#"{"model":{"x":1},"provider":5,"choices":[{"delta":{"content":"ok"}}]}"#)
        #expect(c.model == nil)
        #expect(c.provider == nil)
        #expect(c.choices.first?.delta.content == "ok")
    }

    @Test("skipped chunks are counted and only the first sample is kept, truncated")
    func skippedChunks() {
        var d = StreamDiagnostics()
        d.recordSkipped(String(repeating: "a", count: 1000))
        d.recordSkipped("second")
        #expect(d.skippedChunks == 2)
        #expect(d.firstSkippedSample?.count == StreamDiagnostics.sampleLimit)
    }

    @Test("summary warns on a flattened tool call without structured calls")
    func flattenedWarning() {
        let d = StreamDiagnostics()
        let text = "thinking [tool_use id=call_1 name=get_file_info]"
        let line = d.summary(
            textChars: text.count, structuredToolCalls: 0,
            textHasToolMarker: StreamDiagnostics.containsFlattenedToolMarker(text),
            host: "routerai.ru", model: "m"
        )
        #expect(line.contains("WARNING flattened tool call"))
        #expect(line.contains("finish: none"))
    }

    @Test("no warning when structured calls exist or marker is absent")
    func noWarning() {
        let d = StreamDiagnostics()
        let withCalls = d.summary(textChars: 10, structuredToolCalls: 2, textHasToolMarker: true, host: "h", model: "m")
        let plain = d.summary(textChars: 10, structuredToolCalls: 0, textHasToolMarker: false, host: "h", model: "m")
        #expect(!withCalls.contains("WARNING"))
        #expect(!plain.contains("WARNING"))
    }

    @Test("summary shows upstream model only when it differs from the requested one")
    func upstreamModelShownOnDifference() throws {
        var d = StreamDiagnostics()
        d.record(try chunk(#"{"model":"other/model","choices":[]}"#))
        let differs = d.summary(textChars: 0, structuredToolCalls: 0, textHasToolMarker: false, host: "h", model: "m")
        let same = d.summary(textChars: 0, structuredToolCalls: 0, textHasToolMarker: false, host: "h", model: "other/model")
        #expect(differs.contains("upstreamModel: other/model"))
        #expect(!same.contains("upstreamModel"))
    }
}
