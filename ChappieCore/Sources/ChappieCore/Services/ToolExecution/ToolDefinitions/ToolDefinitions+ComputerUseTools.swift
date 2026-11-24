// ToolDefinitions+ComputerUseTools.swift
// ChappieCore
//
// Computer Use tool definitions — screenshot, move, click, scroll, type.
// Every position is a FRACTION of the monitor (0...1), the single unit used across all the tools:
// it survives any rescaling of the picture on its way to the model.

import Foundation

extension ToolExecutionService {

    func computerUseTools() -> [AITool] {
        [
            computerScreenshotTool(),
            computerMoveTool(),
            computerMoveByTool(),
            computerClickTool(),
            computerScrollTool(),
            computerTypeTool(),
            computerZoomTool(),
            computerElementsTool(),
            computerTargetAXActionTool()
        ]
    }

    private func computerTargetAXActionTool() -> AITool {
        AITool(function: AIFunctionDefinition(
            name: "computer_target_ax_action",
            description: """
            Act on one element of the accessibility directory by NAME — the trusted path, and the \
            cheap one: it finds the element, aims at it exactly, and acts, without moving the cursor \
            by eye and without a magnifier call. Use it whenever computer_elements has listed the \
            target; aim by hand only when AX is unavailable (a canvas, a game, an app that exposes \
            nothing). \
            target is role:name exactly as the directory prints it, for example twist:ViewModels or \
            row:Chappie#2 (the #n picks the second of several equal matches). \
            action is one of the words in that element's [brackets]: press, menu, confirm, inc, dec, \
            pick, cancel — sent as the element's own AX action, or "mouse" to click the element's own \
            point with a real mouse event. Default: press. \
            The answer says what was found, where it aimed, and whether the element's state changed, \
            so a silently ignored action is visible rather than assumed.
            """,
            parameters: AIToolParameters(
                properties: [
                    "target": AIToolProperty(
                        type: "string",
                        description: "role:name as printed by computer_elements, optionally with #n. Example: twist:ViewModels."
                    ),
                    "action": AIToolProperty(
                        type: "string",
                        description: "press (default), menu, confirm, inc, dec, pick, cancel — or mouse to click the element's point with a real mouse event."
                    ),
                    "monitor": AIToolProperty(
                        type: "integer",
                        description: "Zero-based monitor index. 0 = main display (default)."
                    ),
                    "delay": AIToolProperty(
                        type: "number",
                        description: "Seconds to wait after the action before capturing. Default: 1.0. Use 3.0 or more when the app answers over the network or animates slowly."
                    ),
                    "zoom": AIToolProperty(
                        type: "number",
                        description: "Optional magnifier span: when present the result is a native crop around the element instead of the whole monitor. 0.02 shows a 4% wide slice."
                    )
                ],
                required: ["target"]
            )
        ))
    }

    private func computerZoomTool() -> AITool {
        AITool(function: AIFunctionDefinition(
            name: "computer_zoom",
            description: """
            Magnify around a point: returns a 1:1 native crop of the screen, small and sharp, with the \
            cursor visible. Use it when the target is too small to read in a full-screen frame — a \
            disclosure chevron, a checkbox, a one-line list row. \
            The crop's own edges come back as fractions of the MONITOR, so aim with monitor fractions \
            interpolated between those edges; a position inside the crop is not a coordinate. \
            span is half the crop's width as a fraction of the monitor: 0.01 is a 2% wide slice around \
            the point, 0.05 shows 10%. Smaller span = more magnification. \
            The cursor does not move: this only changes what you see. computer_move_to and \
            computer_move_by also accept zoom to move and magnify in one call.
            """,
            parameters: AIToolParameters(
                properties: [
                    "span": AIToolProperty(
                        type: "number",
                        description: "Half the crop width as a fraction of the monitor, 0.005...0.25. 0.02 shows a 4% wide slice. Smaller = more zoom."
                    ),
                    "x": AIToolProperty(type: "number", description: "Horizontal centre of the crop as a fraction 0...1 of the monitor. Default: the cursor."),
                    "y": AIToolProperty(type: "number", description: "Vertical centre of the crop as a fraction 0...1 of the monitor. Default: the cursor."),
                    "monitor": AIToolProperty(
                        type: "integer",
                        description: "Zero-based monitor index. 0 = main display (default)."
                    ),
                    "delay": AIToolProperty(
                        type: "number",
                        description: "Seconds to wait before capturing. Default: 0.3."
                    )
                ],
                required: ["span"]
            )
        ))
    }

    private func computerElementsTool() -> AITool {
        AITool(function: AIFunctionDefinition(
            name: "computer_elements",
            description: """
            Return the accessibility directory for the app under the cursor, together with a fresh \
            screenshot. The directory lists every aimable control — buttons, fields, tabs, menu items, \
            list rows and disclosure chevrons — one per line, each with its geometric CENTRE as a \
            fraction of the monitor. Copy c straight into computer_move_to: the digits are fractions, \
            not pixels, so no arithmetic is involved. \
            Use it when a target is too small or too crowded to place by eye — a disclosure chevron that \
            expands a folder is about 10 points wide, two pixels in the full frame. \
            Each line also lists, in [brackets], the AX actions the element declares (press, menu, \
            confirm, inc, dec, pick), or "disabled" when the control is greyed out and ignores them. \
            Once a target is listed here, act on it with computer_target_ax_action rather than aiming \
            by hand: it takes the name, aims exactly, and reports whether the state changed. \
            Nothing is drawn on the picture; the directory is a reference that rides beside it. \
            The window is chosen the same way a click chooses it: the topmost window under the cursor, \
            so move the cursor over the target window first. \
            Elements that are in the tree but off screen — scrolled away, collapsed, outside the window — \
            are dropped and counted, so the list is what can actually be hit.
            """,
            parameters: AIToolParameters(
                properties: [
                    "limit": AIToolProperty(
                        type: "integer",
                        description: "Maximum number of elements to list, in reading order. Default: 120. Lower it to save tokens on a crowded screen; raise it for long lists."
                    ),
                    "monitor": AIToolProperty(
                        type: "integer",
                        description: "Zero-based monitor index. 0 = main display (default)."
                    )
                ],
                required: []
            )
        ))
    }

    // MARK: - Individual definitions

    private func computerScreenshotTool() -> AITool {
        AITool(function: AIFunctionDefinition(
            name: "computer_screenshot",
            description: """
            Capture one whole monitor as a clean image, exactly as it is on screen, with the real cursor visible. \
            The text result gives the cursor tip as fractions of the monitor, plus how many monitors are connected. \
            Fractions are 0...1 on each axis, (0,0) at the top-left; they are what every tool takes. \
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
            x and y are fractions of the monitor from 0 to 1: 0.5 is the middle of that axis, \
            and the whole range is always valid whatever the screen size or image scale. \
            After moving, returns a fresh screenshot with the cursor at the new position and its fractions. \
            Use this to reach a distant target. For small corrections near the target, use computer_move_by.
            """,
            parameters: AIToolParameters(
                properties: [
                    "x": AIToolProperty(type: "number", description: "Horizontal position as a fraction 0...1 of the monitor width."),
                    "y": AIToolProperty(type: "number", description: "Vertical position as a fraction 0...1 of the monitor height."),
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
            Nudge the cursor by a relative offset, in fractions of the monitor. \
            Positive dx moves right, negative dx moves left. Positive dy moves down, negative dy moves up. \
            0.01 is one percent of the width (height for dy) — the usual size of a fine correction. \
            Returns a fresh screenshot with the cursor at the new position and its fractions.
            """,
            parameters: AIToolParameters(
                properties: [
                    "dx": AIToolProperty(type: "number", description: "Horizontal offset as a fraction 0...1 of the monitor width. Positive = right."),
                    "dy": AIToolProperty(type: "number", description: "Vertical offset as a fraction 0...1 of the monitor height. Positive = down."),
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
