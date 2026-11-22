// ComputerUseTypeToolTests.swift
// ChappieCoreTests
//
// computer_type takes no coordinates any more: the point comes from the pending aim. These tests
// cover the argument decoding, where providers quote scalars ("true", "2.5").

import Testing
import Foundation
@testable import ChappieCore

@Suite("Aimed computer_type arguments")
struct AimedTypeArgumentsTests {

    private func decode(_ json: String) -> ToolExecutionService.AimedTypeArguments? {
        try? JSONDecoder().decode(ToolExecutionService.AimedTypeArguments.self, from: Data(json.utf8))
    }

    @Test("Text alone is enough")
    func textOnly() {
        let a = decode(#"{"text":"hello"}"#)
        #expect(a?.text == "hello")
        #expect(a?.submit == nil)
        #expect(a?.delay == nil)
    }

    @Test("Quoted submit and delay are still read")
    func quotedScalars() {
        let a = decode(#"{"text":"hi","submit":"true","delay":"2.5"}"#)
        #expect(a?.submit?.value == true)
        #expect(a?.delay?.value == 2.5)
    }

    @Test("Native submit and delay are read as they are")
    func nativeScalars() {
        let a = decode(#"{"text":"hi","submit":false,"delay":3}"#)
        #expect(a?.submit?.value == false)
        #expect(a?.delay?.value == 3)
    }

    @Test("Missing text fails the decode")
    func missingText() {
        #expect(decode(#"{"submit":true}"#) == nil)
    }

    @Test("Unicode text survives")
    func unicode() {
        #expect(decode(#"{"text":"Привет, мир 👋"}"#)?.text == "Привет, мир 👋")
    }

    @Test("Old coordinate arguments are ignored, not an error")
    func legacyArgumentsIgnored() {
        let a = decode(#"{"text":"x","x":10,"y":20,"element":3,"screen_index":1}"#)
        #expect(a?.text == "x")
    }
}
