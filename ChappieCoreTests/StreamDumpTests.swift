// StreamDumpTests.swift — when a stream is saved, what the file holds, and that healthy turns stay out of it
import Foundation
import Testing
@testable import ChappieCore

@Suite("Stream dump")
struct StreamDumpTests {

    private func summary(
        text: String = "ok",
        toolCalls: [StreamDumpToolCall] = [],
        finishReason: String? = "stop",
        skippedChunks: Int = 0,
        upstreamModel: String? = nil,
        upstreamProvider: String? = nil
    ) -> StreamDumpSummary {
        StreamDumpSummary(
            date: Date(timeIntervalSince1970: 1_763_000_000),
            host: "routerai.ru",
            path: "/api/v1/chat/completions",
            protocolName: "openai",
            model: "anthropic/claude-sonnet-5.5",
            upstreamModel: upstreamModel,
            upstreamProvider: upstreamProvider,
            finishReason: finishReason,
            chunks: 11,
            skippedChunks: skippedChunks,
            firstSkippedSample: nil,
            text: text,
            toolCalls: toolCalls
        )
    }

    // MARK: - The whole point: healthy streams must not cost a file

    @Test("Healthy stream is not saved")
    func healthyIsNotSaved() {
        let reason = StreamDumpRecorder.reason(for: summary(), forced: false)
        #expect(reason == nil)
    }

    @Test("Forced dump saves even a healthy stream")
    func forcedSaves() {
        #expect(StreamDumpRecorder.reason(for: summary(), forced: true) == .forced)
    }

    // MARK: - Reasons

    @Test("Flattened tool marker is saved")
    func flattenedMarkerIsSaved() {
        let text = "Сейчас запущу.\n[tool_use id=call_1 name=run_terminal]\n{\"command\":\"ls\"}"
        #expect(StreamDumpRecorder.reason(for: summary(text: text), forced: false) == .flattenedToolCall)
    }

    /// The marker is a reason to SAVE a file, never to execute anything: parsing text into a call is
    /// deliberately not implemented, because ordinary prose about tools contains the same characters.
    @Test("Marker is detected even when structured calls exist")
    func markerWinsOverStructuredCalls() {
        let text = "text with [tool_use id=call_1 name=x]"
        let call = StreamDumpToolCall(name: "git_status", arguments: "{}")
        #expect(StreamDumpRecorder.reason(for: summary(text: text, toolCalls: [call]), forced: false)
                == .flattenedToolCall)
    }

    @Test("Skipped chunk is saved")
    func skippedChunkIsSaved() {
        #expect(StreamDumpRecorder.reason(for: summary(skippedChunks: 2), forced: false) == .skippedChunks)
    }

    @Test("Cut tool arguments are saved")
    func truncatedArgumentsAreSaved() {
        let cut = StreamDumpToolCall(name: "json_edit", arguments: "{\"edits\":[{\"op\":\"set\"")
        #expect(StreamDumpRecorder.reason(for: summary(toolCalls: [cut]), forced: false) == .malformedToolArguments)
    }

    @Test("Missing finish reason is saved")
    func missingFinishReasonIsSaved() {
        #expect(StreamDumpRecorder.reason(for: summary(finishReason: nil), forced: false) == .noFinishReason)
    }

    /// Priority matters: the flattened call explains the most, so it must not be hidden by a milder reason.
    @Test("Flattened marker outranks skipped chunks")
    func flattenedOutranksSkipped() {
        let text = "[tool_use id=call_9]"
        #expect(StreamDumpRecorder.reason(for: summary(text: text, finishReason: nil, skippedChunks: 3),
                                          forced: false) == .flattenedToolCall)
    }

    // MARK: - Recorder buffer

    @Test("Empty tool arguments are not valid JSON")
    func emptyArgumentsAreInvalid() {
        #expect(StreamDumpToolCall(name: "x", arguments: "").argumentsAreValidJSON == false)
    }

    @Test("Recorder keeps lines and counts what it dropped")
    func recorderCapsBuffer() throws {
        var recorder = StreamDumpRecorder()
        let line = "data: " + String(repeating: "a", count: 1024)
        let fitting = StreamDumpRecorder.maxCharacters / (line.count + 1)
        for _ in 0..<(fitting + 5) { recorder.record(line) }

        #expect(recorder.isEmpty == false)
        #expect(recorder.droppedLines > 0)
        #expect(recorder.lines.count == fitting + 1)
    }

    // MARK: - File contents

    @Test("File carries the fault and the raw stream")
    func fileHoldsHeaderAndRawLines() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("StreamDumpTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var recorder = StreamDumpRecorder()
        recorder.record("data: {\"choices\":[]}")
        recorder.record("data: [DONE]")

        let badSummary = summary(
            text: "text with [tool_use id=call_1 name=x]",
            toolCalls: [StreamDumpToolCall(name: "git_status", arguments: "{}")],
            upstreamModel: "claude-sonnet-4.5",
            upstreamProvider: "Anthropic"
        )
        let url = try #require(StreamDumpWriter.write(
            recorder: recorder, summary: badSummary, reason: .flattenedToolCall, in: dir
        ))
        let body = try String(contentsOf: url, encoding: .utf8)

        #expect(url.lastPathComponent.hasSuffix("_flattened-tool-call.log"))
        #expect(body.contains("reason: flattened-tool-call"))
        #expect(body.contains("protocol: openai"))
        #expect(body.contains("upstreamModel: claude-sonnet-4.5"))
        #expect(body.contains("provider: Anthropic"))
        #expect(body.contains("flattenedMarker: present in text"))
        #expect(body.contains("[0] git_status"))
        #expect(body.contains("data: {\"choices\":[]}"))
        #expect(body.contains("data: [DONE]"))
    }

    @Test("Nothing is written for an empty recorder")
    func emptyRecorderWritesNothing() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("StreamDumpTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = StreamDumpWriter.write(
            recorder: StreamDumpRecorder(), summary: summary(), reason: .forced, in: dir
        )
        #expect(url == nil)
        #expect(FileManager.default.fileExists(atPath: dir.path) == false)
    }

    @Test("Old dumps are pruned by count")
    func prunesOldFiles() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("StreamDumpTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Names sort chronologically, so the oldest are the first alphabetically.
        for day in 1...StreamDumpWriter.maxFiles + 5 {
            let name = String(format: "2026-01-%02d_00-00-00_forced.log", day)
            try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        var recorder = StreamDumpRecorder()
        recorder.record("data: {}")
        StreamDumpWriter.write(recorder: recorder, summary: summary(), reason: .forced, in: dir)

        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".log") }
        #expect(left.count == StreamDumpWriter.maxFiles)
    }
}
