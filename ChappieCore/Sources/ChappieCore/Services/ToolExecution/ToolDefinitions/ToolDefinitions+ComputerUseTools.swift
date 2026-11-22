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
            Capture the screen and return it as an image. Two modes.
            OVERVIEW — omit width/height. The whole screen, downscaled, with a coordinate grid drawn over it. Read a position off the labelled lines and pass those numbers to computer_click; no estimating from the edges.
            ZOOM — pass x, y, width and height. That region comes back at native display resolution with a finer grid. Use it for small targets where a few pixels decide the outcome: window buttons, toolbar icons, checkboxes, menu items, table cells.
            Grid labels are always pixels of the overview image, so a number read in a zoomed image goes to computer_click unchanged. Pass grid:false for a clean picture when you only want to read content.
            MARKS — pass marks:true to have the controls of the application you are working in boxed and numbered, with a list of them as the tool result. Then click a number (computer_click element:7) instead of a pixel: the centre comes from the system, so small buttons are hit exactly. This is the reliable way to drive another app; pixels are the fallback for apps that report no controls.
            Every click, scroll and keystroke already returns a freshly numbered picture, so take one with marks:true when you need numbers for the first time.
            """,
            parameters: AIToolParameters(
                properties: [
                    "screen_index": AIToolProperty(
                        type: "integer",
                        description: "Zero-based index of the screen to capture. 0 = main display (default). Omit for the main display."
                    ),
                    "marks": AIToolProperty(
                        type: "boolean",
                        description: "Box and number the controls of the other application's window, and return them as a list. Default: false. Numbers are then used by computer_click(element:)."
                    ),
                    "grid": AIToolProperty(
                        type: "boolean",
                        description: "Draw the labelled coordinate grid. Default: true, or false when marks:true."
                    ),
                    "x": AIToolProperty(
                        type: "number",
                        description: "Zoom mode only: left edge of the region, in overview-image pixels."
                    ),
                    "y": AIToolProperty(
                        type: "number",
                        description: "Zoom mode only: top edge of the region, in overview-image pixels."
                    ),
                    "width": AIToolProperty(
                        type: "number",
                        description: "Zoom mode: width of the region in overview-image pixels. Give it together with height; without them the whole screen is returned."
                    ),
                    "height": AIToolProperty(
                        type: "number",
                        description: "Zoom mode: height of the region in overview-image pixels. Give it together with width."
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
            description: "Scroll at a position on the screen. Coordinates are in screenshot-image space. Returns a freshly numbered screenshot taken after the action.",
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
            description: "Type text at the current keyboard focus. Optionally focus a field first — by element number, which is the reliable way — then type. Returns a freshly numbered screenshot taken after the action.",
            parameters: AIToolParameters(
                properties: [
                    "text": AIToolProperty(type: "string", description: "The text to type. Supports Unicode."),
                    "element": AIToolProperty(
                        type: "integer",
                        description: "Number of a field in the latest numbered screenshot: click it to place the focus, then type. Preferred over x/y."
                    ),
                    "x": AIToolProperty(
                        type: "number",
                        description: "Without element: click this position first to focus the input field, then type. Coordinates in screenshot-image space."
                    ),
                    "y": AIToolProperty(
                        type: "number",
                        description: "Without element: click this position first to focus the input field, then type. Coordinates in screenshot-image space."
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
