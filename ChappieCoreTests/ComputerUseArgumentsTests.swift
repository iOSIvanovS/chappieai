// ComputerUseArgumentsTests.swift
// ChappieCoreTests
//
// Providers quote scalars ("true", "400"). A strict decode used to fail on the first quoted value
// and throw away EVERY argument while the call still "succeeded" with default options.

import Testing
import Foundation
@testable import ChappieCore

@Suite("Computer screenshot arguments")
struct ComputerScreenshotArgumentsTests {

    private func parse(_ json: String) -> ComputerScreenshotArguments {
        ComputerScreenshotArguments.parse(Data(json.utf8))
    }

    @Test("Native JSON types are read as they are")
    func native() {
        #expect(parse(#"{"monitor":1}"#).monitor?.value == 1)
    }

    @Test("Quoted values still count")
    func quoted() {
        #expect(parse(#"{"monitor":"1"}"#).monitor?.value == 1)
    }

    @Test("The older screen_index name is still read")
    func legacyIndex() {
        #expect(parse(#"{"screen_index":2}"#).screen_index?.value == 2)
    }

    @Test("A garbled field falls back to defaults for all fields")
    func garbledField() {
        let a = parse(#"{"monitor":"maybe","screen_index":1}"#)
        #expect(a.monitor == nil)
        #expect(a.screen_index == nil)
    }

    @Test("A removed argument such as grid is ignored, not an error")
    func removedGridIsIgnored() {
        #expect(parse(#"{"grid":true,"monitor":1}"#).monitor?.value == 1)
    }

    @Test("Without options nothing is set")
    func defaults() {
        #expect(parse("{}").monitor == nil)
    }

    @Test("Garbage payload falls back to defaults")
    func garbage() {
        let a = ComputerScreenshotArguments.parse(Data("not json".utf8))
        #expect(a.monitor == nil)
        #expect(a.screen_index == nil)
    }
}

@Suite("Lenient scalars")
struct FlexScalarTests {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test("FlexBool accepts bool, string and 0/1")
    func flexBool() {
        struct W: Decodable { let v: FlexBool }
        #expect(decode(W.self, #"{"v":true}"#)?.v.value == true)
        #expect(decode(W.self, #"{"v":"false"}"#)?.v.value == false)
        #expect(decode(W.self, #"{"v":1}"#)?.v.value == true)
        #expect(decode(W.self, #"{"v":0}"#)?.v.value == false)
        #expect(decode(W.self, #"{"v":"nope"}"#) == nil)
    }

    @Test("FlexInt accepts int, whole float and strings, but not 2.5")
    func flexInt() {
        struct W: Decodable { let v: FlexInt }
        #expect(decode(W.self, #"{"v":7}"#)?.v.value == 7)
        #expect(decode(W.self, #"{"v":"7"}"#)?.v.value == 7)
        #expect(decode(W.self, #"{"v":7.0}"#)?.v.value == 7)
        #expect(decode(W.self, #"{"v":"7.0"}"#)?.v.value == 7)
        #expect(decode(W.self, #"{"v":2.5}"#) == nil)
    }
}
