// CurlResponseShapingTests.swift
// ChappieCoreTests
//
// What the model sees of a response: \uXXXX decoding and the `pick` path filter.

import Testing
import Foundation
@testable import ChappieCore

@Suite("Curl-Chappie response shaping")
struct CurlResponseShapingTests {

    // MARK: - \uXXXX decoding

    @Test("Cyrillic escapes are decoded")
    func cyrillic() {
        #expect(CurlUnicodeEscapes.decode(#"{"name":"\u0422\u0435\u0441\u0442"}"#) == #"{"name":"Тест"}"#)
    }

    @Test("Surrogate pairs become one character")
    func surrogatePair() {
        #expect(CurlUnicodeEscapes.decode(#""\ud83d\ude00""#) == "\"😀\"")
    }

    @Test("ASCII escapes stay, so JSON structure cannot change")
    func asciiStays() {
        let text = #"{"a":"x\u0022y","b":"\u005c","c":"\u000a"}"#
        #expect(CurlUnicodeEscapes.decode(text) == text)
    }

    @Test("An escaped backslash before u is not a unicode escape")
    func escapedBackslash() {
        let text = #"{"a":"\\u0422"}"#
        #expect(CurlUnicodeEscapes.decode(text) == text)
    }

    @Test("Malformed and unpaired escapes are left as written")
    func malformed() {
        for text in [#"\u04"#, #"\u04zz"#, #"\ud83d"#, #"\ud83dx"#, #"\ude00"#, #"\ud83d\u0041"#, "trailing \\"] {
            #expect(CurlUnicodeEscapes.decode(text) == text, "\(text)")
        }
    }

    @Test("Text without escapes is returned untouched")
    func noEscapes() {
        #expect(CurlUnicodeEscapes.decode("plain Тест") == "plain Тест")
    }

    @Test("Decoded text stays valid JSON for ordinary strings")
    func staysValidJSON() throws {
        let decoded = CurlUnicodeEscapes.decode(#"{"title":"\u041e\u0431\u044a\u0435\u043a\u0442","n":5}"#)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? [String: Any])
        #expect(object["title"] as? String == "Объект")
    }

    // MARK: - pick

    private let sample = #"""
    {"data":{"constructions":[{"id":1,"name":"A","note":null},{"id":2,"name":"B"}],"folders":[]},"paginate":{"total":13}}
    """#

    @Test("Paths and wildcards are collected into one object")
    func pickBasics() throws {
        let out = try #require(CurlJSONPath.pick(["data.constructions[*].id", "paginate.total", "data.constructions[1].name"], from: sample))
        #expect(out == #"{"data.constructions[*].id":[1,2],"paginate.total":13,"data.constructions[1].name":"B"}"#)
    }

    @Test("A missing path is null, a null field inside a wildcard stays null")
    func pickMissing() throws {
        let out = try #require(CurlJSONPath.pick(["nope", "data.constructions[*].note"], from: sample))
        #expect(out == #"{"nope":null,"data.constructions[*].note":[null,null]}"#)
    }

    @Test("Non-JSON text and malformed paths give nil so the caller can fall back")
    func pickFallback() {
        #expect(CurlJSONPath.pick(["a"], from: "not json") == nil)
        #expect(CurlJSONPath.pick(["a[x]"], from: sample) == nil)
        #expect(CurlJSONPath.pick([], from: sample) == nil)
    }

    @Test("Strings are escaped and slashes are not")
    func pickEscaping() throws {
        let out = try #require(CurlJSONPath.pick(["u"], from: #"{"u":"a\"b/c"}"#))
        #expect(out == #"{"u":"a\"b/c"}"#)
    }

    @Test("A wildcard is not accepted by single-value extraction")
    func wildcardNotInExtract() {
        #expect(CurlJSONPath.extract("data.constructions[*].id", from: Data(sample.utf8)) == nil)
        #expect(CurlJSONPath.extract("data.constructions[1].id", from: Data(sample.utf8)) == "2")
    }

    @Test("pick argument accepts a bare path or a JSON array")
    func pickArgument() throws {
        #expect(try CurlToolArguments.pick(["pick": "data.id"]) == ["data.id"])
        #expect(try CurlToolArguments.pick(["pick": #"["a.b", " c "]"#]) == ["a.b", "c"])
        #expect(try CurlToolArguments.pick([:]) == [])
        #expect(throws: CurlToolArguments.Failure.self) { _ = try CurlToolArguments.pick(["pick": "[1,2]"]) }
    }

    // MARK: - End to end through the engine

    private struct NoValues: CurlSecretValueProvider {
        func value(secretId: UUID, field: CurlSecretField) -> String? { nil }
    }

    private final class Stub: CurlTransport, @unchecked Sendable {
        let body: String
        init(_ body: String) { self.body = body }
        func send(_ request: URLRequest) async throws -> CurlRawResponse {
            CurlRawResponse(status: 200, headers: [CurlHeader("Content-Type", "application/json")], body: Data(body.utf8))
        }
    }

    private var context: CurlContext {
        CurlContext(hosts: [CurlHost(name: "Dev", origin: "https://dev.x.ru", permission: .readOnly)],
                    secrets: [], values: NoValues())
    }

    @Test("The engine decodes escapes and picks fields")
    func engineShapesBody() async throws {
        let escaped = #"{"data":{"items":[{"id":1,"name":"\u0422\u0435\u0441\u0442","refresh_token":"abcdef"}]}}"#
        let engine = CurlEngine(transport: Stub(escaped))
        let full = try await engine.send(CurlRequestSpec(method: "GET", url: "https://dev.x.ru/a"), context: context)
        #expect(full.body.contains("Тест"))
        #expect(full.body.contains(#""refresh_token":"<redacted>""#))

        let picked = try await engine.send(
            CurlRequestSpec(method: "GET", url: "https://dev.x.ru/a", pick: ["data.items[*].name", "data.items[*].refresh_token"]),
            context: context)
        #expect(picked.body == #"{"data.items[*].name":["Тест"],"data.items[*].refresh_token":["<redacted>"]}"#)
        #expect(picked.notes.contains { $0.contains("pick") })
    }

    @Test("pick on a non-JSON body keeps the body and says so")
    func engineIgnoresBadPick() async throws {
        let engine = CurlEngine(transport: Stub("plain text"))
        let response = try await engine.send(
            CurlRequestSpec(method: "GET", url: "https://dev.x.ru/a", pick: ["a"]), context: context)
        #expect(response.body == "plain text")
        #expect(response.notes.contains { $0.contains("ignored") })
    }

    @Test("A known secret written as \\uXXXX is still redacted after decoding")
    func redactionSeesDecodedText() async throws {
        let secret = CurlSecret(name: "pw", kind: .plain, hostOrigin: "https://dev.x.ru")
        struct Values: CurlSecretValueProvider {
            let id: UUID
            func value(secretId: UUID, field: CurlSecretField) -> String? { secretId == id ? "Пароль-123" : nil }
        }
        let ctx = CurlContext(hosts: [CurlHost(name: "Dev", origin: "https://dev.x.ru", permission: .readOnly)],
                              secrets: [secret], values: Values(id: secret.id))
        let engine = CurlEngine(transport: Stub(#"{"echo":"\u041f\u0430\u0440\u043e\u043b\u044c-123"}"#))
        let response = try await engine.send(CurlRequestSpec(method: "GET", url: "https://dev.x.ru/a"), context: ctx)
        #expect(!response.body.contains("Пароль-123"))
        #expect(response.body.contains("<redacted:secret:pw>") || response.body.contains("<redacted"))
    }
}
