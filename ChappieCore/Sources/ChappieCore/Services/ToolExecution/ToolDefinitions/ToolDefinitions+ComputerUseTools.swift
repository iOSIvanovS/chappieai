// ToolDefinitions+ComputerUseTools.swift
// ChappieCore
//
// Computer Use tool definitions — screenshot, move, click, scroll, type.
// The model works entirely in picture pixels: it sees a screenshot, reads cursor coordinates
// from the text, moves the cursor with computer_move_to or computer_move_by, then clicks.

import Foundation

extension ToolExecutionService {

    func computerUseTools() -> [AITool] {
        [
            computerScreenshotTool(),
            computerMoveTool(),
            computerMoveByTool(),
            computerClickTool(),
            computerScrollTool(),
            computerTypeTool()
        ]
    }

    // MARK: - Individual definitions

    private func computerScreenshotTool() -> AITool {
        AITool(function: AIFunctionDefinition(
            name: "computer_screenshot",
            description: """
            Capture one whole monitor as a clean image, exactly as it is on screen, with the real cursor visible. \
            The text result says how many monitors are connected, the picture size in pixels, and the current cursor \
            position in picture pixels (0,0 = top-left). \
            All coordinates use picture pixels — the same units as computer_move_to and computer_move_by. \
            Use the monitor parameter to look at a different monitor.
            """,
            parameters: AIToolParameters(
                properties: [
                    "monitor": AIToolProperty(
                        type: "integer",
                        description: "Zero-based monitor index. 0 = main display (default)."
                    )
                ],
                required: []
            )
        ))
    }

    private func computerMoveTool() -> AITool {
        AITool(function: AIFunctionDefinition(
            name: "computer_move_to",
            description: """
            Move the cursor to an absolute position on the screen. \
            x and y are picture pixels of the monitor image (0,0 = top-left corner). \
            Read the picture size from the latest computer_screenshot result to know the valid range. \
            After moving, returns a fresh screenshot with the cursor at the new position and updated cursor coordinates. \
            Use this to reach a distant target. For small corrections near the target, use computer_move_by.
            """,
            parameters: AIToolParameters(
                properties: [
                    "x": AIToolProperty(type: "number", description: "Horizontal position in picture pixels."),
                    "y": AIToolProperty(type: "number", description: "Vertical position in picture pixels."),
                    "monitor": AIToolProperty(
                        type: "integer",
                        description: "Zero-based monitor index. 0 = main display (default)."
                    ),
                    "delay": AIToolProperty(
                        type: "number",
                        description: "Seconds to wait after moving before taking the screenshot. Default: 0.3."
                    )
                ],
                required: ["x", "y"]
            )
        ))
    }

    private func computerMoveByTool() -> AITool {
        AITool(function: AIFunctionDefinition(
            name: "computer_move_by",
            description: """
            Nudge the cursor by a relative offset in picture pixels. \
            Positive dx moves right, negative dx moves left. Positive dy moves down, negative dy moves up. \
            Use this to make small corrections when the cursor is already near the target. \
            Returns a fresh screenshot with the cursor at the new position and updated cursor coordinates.
            """,
            parameters: AIToolParameters(
                properties: [
                    "dx": AIToolProperty(type: "number", description: "Horizontal offset in picture pixels. Positive = right."),
                    "dy": AIToolProperty(type: "number", description: "Vertical offset in picture pixels. Positive = down."),
                    "monitor": AIToolProperty(
                        type: "integer",
                        description: "Zero-based monitor index. 0 = main display (default)."
                    ),
                    "delay": AIToolProperty(
                        type: "number",
                        description: "Seconds to wait after moving before taking the screenshot. Default: 0.3."
                    )
                ],
                required: []
            )
        ))
    }

    private func computerClickTool() -> AITool {
        AITool(function: AIFunctionDefinition(
            name: "computer_click",
            description: """
            Click at the current cursor position. Move the cursor to the target first with computer_move_to or \
            computer_move_by, verify it sits on the target in the returned screenshot, then call computer_click. \
            Returns a screenshot taken after the click.
            """,
            parameters: AIToolParameters(
                properties: [
                    "button": AIToolProperty(
                        type: "string",
                        description: "Mouse button to use: 'left' (default), 'right', or 'middle'."
                    ),
                    "count": AIToolProperty(
                        type: "integer",
                        description: "Number of clicks: 1 for a single click (default), 2 for a double-click."
                    ),
                    "delay": AIToolProperty(
                        type: "number",
                        description: "Seconds to wait after the click before taking the screenshot. Default: 1.0. Use 3.0 or more when clicking a link or button that triggers navigation or a slow animation."
                    ),
                    "monitor": AIToolProperty(
                        type: "integer",
                        description: "Zero-based monitor index for the result screenshot. 0 = main display (default)."
                    )
                ],
                required: []
            )
        ))
    }

    private func computerScrollTool() -> AITool {
        AITool(function: AIFunctionDefinition(
            name: "computer_scroll",
            description: "Scroll at a position on a monitor. Pass x and y as fractions from 0 to 1 of that monitor's image (0.5, 0.5 is the centre); no aim is needed. Positive dy scrolls down, positive dx scrolls right. Returns a clean screenshot of the monitor taken after the action.",
            parameters: AIToolParameters(
                properties: [
                    "x": AIToolProperty(type: "number", description: "Horizontal position of the scroll target as a fraction 0...1 of the monitor image."),
                    "y": AIToolProperty(type: "number", description: "Vertical position of the scroll target as a fraction 0...1 of the monitor image."),
                    "dx": AIToolProperty(
                        type: "number",
                        description: "Horizontal scroll amount in ticks. Negative = left, positive = right. One screen-width ≈ 15–20 ticks."
                    ),
                    "dy": AIToolProperty(
                        type: "number",
                        description: "Vertical scroll amount in ticks. Negative = up, positive = down. One screen-height ≈ 15–20 ticks."
                    ),
                    "delay": AIToolProperty(
                        type: "number",
                        description: "Seconds to wait after scrolling before taking the screenshot. Default: 1.0."
                    ),
                    "monitor": AIToolProperty(
                        type: "integer",
                        description: "Zero-based monitor index. 0 = main display (default)."
                    )
                ],
                required: ["x", "y"]
            )
        ))
    }

    private func computerTypeTool() -> AITool {
        AITool(function: AIFunctionDefinition(
            name: "computer_type",
            description: """
            Move the cursor to an input field with computer_move_to, then call this tool to click it and paste text. \
            The clipboard is saved and restored around the paste. Returns a screenshot after typing.
            """,
            parameters: AIToolParameters(
                properties: [
                    "text": AIToolProperty(type: "string", description: "The text to enter. Supports Unicode."),
                    "submit": AIToolProperty(
                        type: "boolean",
                        description: "If true — press Return after typing. Useful for search fields and single-line forms. Default: false."
                    ),
                    "delay": AIToolProperty(
                        type: "number",
                        description: "Seconds to wait after typing (and submitting, if submit=true) before taking the screenshot. Default: 1.0. Use 3.0 when submit triggers navigation."
                    ),
                    "monitor": AIToolProperty(
                        type: "integer",
                        description: "Zero-based monitor index for the result screenshot. 0 = main display (default)."
                    )
                ],
                required: ["text"]
            )
        ))
    }
}
