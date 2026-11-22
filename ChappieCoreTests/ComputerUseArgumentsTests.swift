// ComputerUseArgumentsTests.swift
// ChappieCoreTests
//
// Providers quote scalars ("true", "400"). A strict decode used to fail on the first quoted value
// and throw away EVERY argument, so marks:true, the zoom region and grid:false were all ignored
// at once while the call still "succeeded" with a plain gridded overview.

import Testing
import Foundation
import CoreGraphics
@testable import ChappieCore

@Suite("Computer screenshot arguments")
struct ComputerScreenshotArgumentsTests {

    private func parse(_ json: String) -> ComputerScreenshotArguments {
        ComputerScreenshotArguments.parse(Data(json.utf8))
    }

    @Test("Native JSON types are read as they are")
    func native() {
        let a = parse(#"{"marks":true,"grid":false,"x":10,"y":20,"width":300,"height":200,"screen_index":1}"#)
        #expect(a.wantsMarks)
        #expect(!a.wantsGrid)
        #expect(a.region == CGRect(x: 10, y: 20, width: 300, height: 200))
        #expect(a.screen_index?.value == 1)
    }

    @Test("Quoted booleans still count — the bug that made marks:true vanish")
    func quotedBooleans() {
        let a = parse(#"{"marks":"true","grid":"false"}"#)
        #expect(a.wantsMarks)
        #expect(!a.wantsGrid)
        #expect(parse(#"{"marks":"TRUE"}"#).wantsMarks)
    }

    @Test("Quoted numbers still define the zoom region")
    func quotedNumbers() {
        let a = parse(#"{"x":"0","y":"60","width":"400","height":"300"}"#)
        #expect(a.region == CGRect(x: 0, y: 60, width: 400, height: 300))
    }

    @Test("One garbled field does not discard the others")
    func independentFields() {
        // A single bad value fails the whole decode, so the contract is: fall back to a plain
        // overview, never to a half-read request. The valid siblings are not trusted either.
        let a = parse(#"{"marks":"maybe","x":0,"y":0,"width":100,"height":100}"#)
        #expect(!a.wantsMarks)
        #expect(a.region == nil)
    }

    @Test("Without options: whole screen, grid on, no marks")
    func defaults() {
        let a = parse("{}")
        #expect(!a.wantsMarks)
        #expect(a.wantsGrid)
        #expect(a.region == nil)
    }

    @Test("Marks switch the grid off unless it is asked for explicitly")
    func marksImplyNoGrid() {
        #expect(!parse(#"{"marks":true}"#).wantsGrid)
        #expect(parse(#"{"marks":true,"grid":true}"#).wantsGrid)
    }

    @Test("A region needs both sizes")
    func regionNeedsSizes() {
        #expect(parse(#"{"x":10,"y":10}"#).region == nil)
        #expect(parse(#"{"x":10,"y":10,"width":1,"height":1}"#).region == nil)
    }

    @Test("Garbage payload falls back to defaults")
    func garbage() {
        let a = ComputerScreenshotArguments.parse(Data("not json".utf8))
        #expect(!a.wantsMarks)
        #expect(a.region == nil)
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
