// ComputerUseRoutingTests.swift
// ChappieCoreTests
//
// Every computer tool may answer with text plus a picture, and the size gate still refuses an
// oversized text half.

import Testing
import Foundation
@testable import ChappieCore

@Suite("Computer tool result routing")
struct ComputerResultRoutingTests {

    @Test("All computer tools may answer with text plus a picture")
    func allowed() {
        for tool in ["computer_screenshot", "computer_move_to", "computer_move_by", "computer_click",
                     "computer_scroll", "computer_type", "computer_zoom", "computer_elements"] {
            #expect(ToolExecutionService.textAndImageTools.contains(tool))
            #expect(ToolExecutionService.imageResultTools.contains(tool))
        }
        // Adding the computer tools must not remove the document readers.
        for tool in ToolExecutionService.documentImageTools {
            #expect(ToolExecutionService.textAndImageTools.contains(tool))
        }
    }

    @Test("A screenshot result survives the size gate, and an oversized text half does not")
    func guardPasses() {
        let result = ToolImageResult(
            text: "Monitor 0 of 1 connected (indexes 0...0), image 1440x932.",
            images: [.init(label: "Screenshot", dataURI: "data:image/jpeg;base64,AAAA")]
        ).encoded()
        #expect(OutputGuard.apply(toolName: "computer_screenshot", output: result) == result)

        // The picture is exempt from the text limit, the text is not.
        let bloated = ToolImageResult(
            text: String(repeating: "A", count: OutputGuard.readLimit + 1),
            images: [.init(label: "Screenshot", dataURI: "data:image/jpeg;base64,AAAA")]
        ).encoded()
        #expect(OutputGuard.apply(toolName: "computer_screenshot", output: bloated).contains("NOT PASSED"))
    }
}
