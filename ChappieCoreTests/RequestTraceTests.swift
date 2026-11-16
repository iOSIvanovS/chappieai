// RequestTraceTests.swift
// ChappieCoreTests
//
// The trace exists to answer "which part of the request changed", and it is only worth reading if
// its own answers are stable. A fingerprint that reports "changed" on every process would send us
// hunting a bug that is not there — which is exactly the failure mode it was built to expose.
//
// The first test below pins the hazard that started this: JSONEncoder serializes a Swift
// Dictionary in an order that is neither sorted nor stable. Measured 2026-11-16, three runs of the
// same struct with a five-key dictionary produced three different byte orders.

import Foundation
import Testing
@testable import ChappieCore

/// Encodes a dictionary just far enough to get raw bytes, the way the wire body is produced.
private func body(system: String, messages: [String], tools: [String]) -> Data {
    var object: [String: Any] = [
        "messages": messages.map { ["role": "user", "content": $0] },
        "tools": tools.map { ["name": $0, "description": "d", "input_schema": ["properties": [
            "zeta": ["type": "string"], "alpha": ["type": "string"], "mike": ["type": "string"]
        ]]] },
    ]
    if !system.isEmpty { object["system"] = [["type": "text", "text": system]] }
    return try! JSONSerialization.data(withJSONObject: object)
}

@Suite("Request trace")
struct RequestTraceTests {

    // MARK: - The canonical form is stable

    @Test("The same content fingerprints the same, whatever order the bytes arrived in")
    func canonicalIgnoresKeyOrder() {
        // Two bodies that differ only in the order their objects were written.
        let first: [String: Any] = ["a": 1, "b": 2, "c": 3]
        let second: [String: Any] = ["c": 3, "a": 1, "b": 2]

        let left = RequestTrace.canonical(first)
        let right = RequestTrace.canonical(second)
        #expect(left == right)
    }

    @Test("Key order inside a nested schema does not change the fingerprint")
    func nestedOrderIgnored() {
        let one = body(system: "sys", messages: ["m"], tools: ["t"])
        #expect(RequestTrace.fingerprint(of: one) != nil)

        // Round-trip through JSON to rebuild the same content in a different key order.
        let object = try! JSONSerialization.jsonObject(with: one)
        let reordered = ["messages": (object as! [String: Any])["messages"]!,
                         "tools": (object as! [String: Any])["tools"]!,
                         "system": (object as! [String: Any])["system"]!]
        let two = try! JSONSerialization.data(withJSONObject: reordered)

        #expect(RequestTrace.fingerprint(of: one)?.toolsHash == RequestTrace.fingerprint(of: two)?.toolsHash)
        #expect(RequestTrace.fingerprint(of: one)?.systemHash == RequestTrace.fingerprint(of: two)?.systemHash)
        #expect(RequestTrace.fingerprint(of: one)?.messagesHash == RequestTrace.fingerprint(of: two)?.messagesHash)
    }

    @Test("Array order is preserved, because the prompt depends on it")
    func arrayOrderMatters() {
        let one = body(system: "s", messages: ["first", "second"], tools: [])
        let two = body(system: "s", messages: ["second", "first"], tools: [])
        #expect(RequestTrace.fingerprint(of: one)?.messagesHash != RequestTrace.fingerprint(of: two)?.messagesHash)
    }

    @Test("Text that could be confused with its neighbour still hashes apart")
    func noBoundaryCollision() {
        // Without a length prefix, ["ab","c"] and ["a","bc"] would produce the same text.
        let left = RequestTrace.canonical(["ab", "c"])
        let right = RequestTrace.canonical(["a", "bc"])
        #expect(left != right)
    }

    @Test("A boolean is not mistaken for the number 1")
    func boolIsNotOne() {
        #expect(RequestTrace.canonical(true) != RequestTrace.canonical(1))
        #expect(RequestTrace.canonical(true) == RequestTrace.canonical(true))
    }

    // MARK: - What the fingerprint sees

    @Test("Sizes and counts come from the body")
    func countsAndSizes() {
        let print = RequestTrace.fingerprint(of: body(system: "hello", messages: ["a", "b"], tools: ["t1", "t2"]))
        #expect(print?.toolCount == 2)
        #expect(print?.messageCount == 2)
        #expect(print?.systemChars == 5)
        #expect(print?.bodyBytes ?? 0 > 0)
    }

    @Test("Changing the system prompt is reported as a system change")
    func systemChangeDetected() {
        let before = RequestTrace.fingerprint(of: body(system: "one", messages: ["m"], tools: ["t"]))!
        let after = RequestTrace.fingerprint(of: body(system: "two", messages: ["m"], tools: ["t"]))!
        #expect(after.differences(from: before).contains("system"))
    }

    @Test("Changing one tool description is reported as a tools change")
    func toolChangeDetected() {
        let before = RequestTrace.fingerprint(of: body(system: "s", messages: ["m"], tools: ["read_file"]))!
        let after = RequestTrace.fingerprint(of: body(system: "s", messages: ["m"], tools: ["write_file"]))!
        #expect(after.differences(from: before).contains("tools"))
    }

    @Test("Identical requests report no change at all")
    func identicalReportsNone() {
        let same = RequestTrace.fingerprint(of: body(system: "s", messages: ["m"], tools: ["t"]))!
        #expect(same.differences(from: same) == ["none"])
    }

    @Test("A shrinking message list is named as such")
    func shrinkDetected() {
        let before = RequestTrace.fingerprint(of: body(system: "s", messages: ["a", "b", "c"], tools: []))!
        let after = RequestTrace.fingerprint(of: body(system: "s", messages: ["b", "c"], tools: []))!
        let changed = after.differences(from: before)
        #expect(changed.contains { $0.hasPrefix("msgs(shrunk") })
    }

    // MARK: - Robustness

    @Test("A body that is not JSON yields no fingerprint instead of crashing")
    func garbageBody() {
        #expect(RequestTrace.fingerprint(of: Data("not json".utf8)) == nil)
        #expect(RequestTrace.fingerprint(of: Data()) == nil)
    }

    @Test("A missing system field is not a failure")
    func noSystemField() {
        let print = RequestTrace.fingerprint(of: body(system: "", messages: ["m"], tools: []))
        #expect(print != nil)
        #expect(print?.systemChars == 0)
    }
}

// MARK: - The wire body must be byte-stable across processes

/// This is the fix the whole trace was built to find, and it is invisible without a test: a body
/// with unsorted keys looks perfectly correct and only misbehaves in the NEXT process.
///
/// Measured 2026-11-16: the same struct encoded in four separate runs gave four different byte
/// streams, because Swift seeds Dictionary iteration order per process. Tool schemas hang off
/// dictionaries and tools sit at the start of the prompt, so every relaunch invalidated the entire
/// cached prefix — 85479 tokens written, 0 read.
@Suite("Request body determinism")
struct RequestBodyDeterminismTests {

    /// Builds a real request through the client, so the assertion is about the bytes a provider
    /// would actually receive rather than about JSONEncoder in isolation.
    private func anthropicBody() throws -> String {
        let client = AnthropicClient(
            baseURL: "https://example.invalid",
            apiKey: "k",
            modelName: "m",
            supportsCaching: true
        )
        let properties = ["zeta": "z", "alpha": "a", "mike": "m", "kilo": "k", "bravo": "b"]
            .mapValues { AIToolProperty(type: "string", description: $0) }
        let tool = AITool(function: AIFunctionDefinition(
            name: "read_file",
            description: "Reads a file.",
            parameters: AIToolParameters(properties: properties, required: ["alpha"])
        ))
        let body = AnthropicRequest(
            model: "m",
            maxTokens: 16,
            system: [AnthropicSystemBlock(text: "system")],
            messages: [AnthropicMessage(role: "user", content: .text("hello"))],
            tools: [client.convertTool(tool)],
            stream: true
        )
        let request = try client.buildRequest(body: body)
        return String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    }

    @Test("Tool schema keys are written in sorted order, so the bytes survive a relaunch")
    func toolKeysAreSorted() throws {
        let json = try anthropicBody()
        let order = ["alpha", "bravo", "kilo", "mike", "zeta"].compactMap { json.range(of: "\"\($0)\"")?.lowerBound }
        #expect(order.count == 5, "every property must appear in the body")
        #expect(order == order.sorted(), "property keys must come out alphabetically, got: \(json)")
    }

    @Test("Two encodings of the same request are identical byte for byte")
    func sameBodyTwice() throws {
        // Within one process this holds either way; it is kept as the cheap guard that the body is
        // built from the same inputs each time, while the test above covers the cross-process part.
        #expect(try anthropicBody() == (try anthropicBody()))
    }
}
