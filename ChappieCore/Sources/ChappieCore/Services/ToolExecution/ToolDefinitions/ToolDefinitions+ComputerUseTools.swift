// ToolDefinitions+ComputerUseTools.swift
// ChappieCore
//
// Computer Use tool definitions — screenshot, click, scroll, type.
// Full implementation lives in ChappieMCPCore; these definitions tell the model what the tools
// do and what arguments they accept. The actual execution is routed through the MCP socket.

import Foundation

extension ToolExecutionService {

    func computerUseTools() -> [AITool] {
        [
            computerScreenshotTool(),
            computerClickTool(),
            computerScrollTool(),
            computerTypeTool()
        ]
    }

    // MARK: - Individual definitions

    private func computerScreenshotTool() -> AITool {
        AITool(function: AIFunctionDefinition(
            name: "computer_screenshot",
            description: "Capture a screenshot of the screen and return it as an image. Use to observe the current state of the screen before acting, or to verify the result of a previous action without performing a new one.",
            parameters: AIToolParameters(
                properties: [
                    "screen_index": AIToolProperty(
                        type: "integer",
                        description: "Zero-based index of the screen to capture. 0 = main display (default). Omit for the main display."
                    )
                ],
                required: []
            )
        ))
    }

    private func computerClickTool() -> AITool {
        AITool(function: AIFunctionDefinition(
            name: "computer_click",
            description: "Click at a position on the screen. Coordinates are in the space of the screenshot image returned by computer_screenshot — the app maps them back to real screen pixels automatically. Returns a screenshot taken after the action.",
            parameters: AIToolParameters(
                properties: [
                    "x": AIToolProperty(type: "number", description: "Horizontal position in screenshot-image pixels."),
                    "y": AIToolProperty(type: "number", description: "Vertical position in screenshot-image pixels."),
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
                    "screen_index": AIToolProperty(
                        type: "integer",
                        description: "Zero-based index of the screen. 0 = main display (default)."
                    )
                ],
                required: ["x", "y"]
            )
        ))
    }

    private func computerScrollTool() -> AITool {
        AITool(function: AIFunctionDefinition(
            name: "computer_scroll",
            description: "Scroll at a position on the screen. Coordinates are in screenshot-image space. Returns a screenshot taken after the action.",
            parameters: AIToolParameters(
                properties: [
                    "x": AIToolProperty(type: "number", description: "Horizontal position of the scroll target in screenshot-image pixels."),
                    "y": AIToolProperty(type: "number", description: "Vertical position of the scroll target in screenshot-image pixels."),
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
                    "screen_index": AIToolProperty(
                        type: "integer",
                        description: "Zero-based index of the screen. 0 = main display (default)."
                    )
                ],
                required: ["x", "y", "dy"]
            )
        ))
    }

    private func computerTypeTool() -> AITool {
        AITool(function: AIFunctionDefinition(
            name: "computer_type",
            description: "Type text at the current keyboard focus. Optionally click a target first to place the focus, then type. Returns a screenshot taken after the action.",
            parameters: AIToolParameters(
                properties: [
                    "text": AIToolProperty(type: "string", description: "The text to type. Supports Unicode."),
                    "x": AIToolProperty(
                        type: "number",
                        description: "If provided together with y — click this position first to focus the input field, then type. Coordinates in screenshot-image space."
                    ),
                    "y": AIToolProperty(
                        type: "number",
                        description: "If provided together with x — click this position first to focus the input field, then type. Coordinates in screenshot-image space."
                    ),
                    "submit": AIToolProperty(
                        type: "boolean",
                        description: "If true — press Return after typing. Useful for search fields and single-line forms. Default: false."
                    ),
                    "delay": AIToolProperty(
                        type: "number",
                        description: "Seconds to wait after typing (and submitting, if submit=true) before taking the screenshot. Default: 1.0. Use 3.0 when submit triggers navigation."
                    ),
                    "screen_index": AIToolProperty(
                        type: "integer",
                        description: "Zero-based index of the screen. 0 = main display (default)."
                    )
                ],
                required: ["text"]
            )
        ))
    }
}
