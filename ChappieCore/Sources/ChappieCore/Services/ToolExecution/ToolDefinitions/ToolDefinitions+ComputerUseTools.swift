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
            computerAimTool(),
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
            Capture one whole monitor as a clean image, exactly as it is on screen. The text result says how many monitors are connected, so you can look at any of them with the monitor parameter.
            To click, do not read pixel coordinates off this picture: pick the area, call computer_aim with x and y as fractions 0...1 of this image, check the crosshair, then call computer_click.
            Pass grid:true only if you need help choosing the area: it draws a coarse 10x10 grid with lines labelled 0.1 ... 0.9, which are the same fractions computer_aim takes. The grid is off by default so you see the true screen.
            """,
            parameters: AIToolParameters(
                properties: [
                    "monitor": AIToolProperty(
                        type: "integer",
                        description: "Zero-based monitor index. 0 = main display (default)."
                    ),
                    "grid": AIToolProperty(
                        type: "boolean",
                        description: "Draw the coarse fraction grid (step 0.1). Default: false."
                    )
                ],
                required: []
            )
        ))
    }

    private func computerAimTool() -> AITool {
        AITool(function: AIFunctionDefinition(
            name: "computer_aim",
            description: """
            Aim at a point before clicking. Pass x and y as fractions from 0 to 1 of the monitor image (x=0.5, y=0.5 is the centre, 0,0 is the top-left corner). Returns a native-resolution square crop around that point, about 200 points on a side, with a crosshair whose intersection is the exact point. Judge whether it sits on the target; if not, call computer_aim again with corrected fractions, as many times as needed. The latest aim is remembered for the click.
            """,
            parameters: AIToolParameters(
                properties: [
                    "x": AIToolProperty(type: "number", description: "Horizontal position as a fraction 0...1 of the monitor image."),
                    "y": AIToolProperty(type: "number", description: "Vertical position as a fraction 0...1 of the monitor image."),
                    "monitor": AIToolProperty(
                        type: "integer",
                        description: "Zero-based monitor index. 0 = main display (default)."
                    )
                ],
                required: ["x", "y"]
            )
        ))
    }

    private func computerClickTool() -> AITool {
        AITool(function: AIFunctionDefinition(
            name: "computer_click",
            description: """
            Click the point set by the latest computer_aim. This tool takes no coordinates: call computer_aim first, check that the crosshair sits on the target, then call computer_click. One aim is used up by one click, so a second click needs a new aim. The click goes to the monitor that was aimed at.
            Returns a screenshot taken after the action.
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
            description: "Click the point set by the latest computer_aim to focus the input field, then paste the given text there. Takes no coordinates: call computer_aim at the field first and check the crosshair. An aim is used up by one click or type, so a second call needs a new aim. The clipboard is saved and restored around the paste. Returns a screenshot of the aimed monitor taken after the action.",
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
                    )
                ],
                required: ["text"]
            )
        ))
    }
}
