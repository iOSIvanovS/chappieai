import Foundation

extension AIOrchestrator {

    // MARK: - Tool Execution

    func executeToolCalls(
        _ toolCalls: [AIToolCall],
        sessionHistory: inout [AIMessage],
        loopGuard: inout LoopGuard,
        collectedOutputFiles: inout [String],
        onToolCall: @Sendable (String, String) -> Void,
        onTerminalOutput: (@Sendable (String) -> Void)? = nil,
        onTerminalStart: (@Sendable (String) -> Void)? = nil,
        onTerminalFinish: (@Sendable () -> Void)? = nil
    ) async throws {
        let terminalToolNames: Set<String> = ["run_terminal", "run_ssh"]

        for toolCall in toolCalls {
            let toolName = toolCall.function.name
            let arguments = toolCall.function.arguments
            let targetPath = extractTargetPath(from: arguments)
            let signature = "\(toolName)|\(arguments)"
            let isTerminalTool = terminalToolNames.contains(toolName)
            let resultString: String

            if loopGuard.shouldBlock(signature: signature) {
                // 3rd identical call whose result never changed: nothing new can come out of it.
                resultString = LoopGuard.blockedMessage(toolName: toolName)
                print("[AIOrchestrator] Loop guard: \(toolName) blocked (3rd identical call, identical results)")
            } else {
                // Access control happens inside toolService.execute (ToolPolicy): denied calls come
                // back as an explanatory message, so the tool_call always gets its tool result.
                onToolCall(toolName, targetPath)
                if isTerminalTool {
                    onTerminalStart?(extractCommand(from: arguments))
                }
                resultString = await toolService.execute(call: toolCall, onOutput: onTerminalOutput)
                if isTerminalTool {
                    onTerminalFinish?()
                }
                loopGuard.record(signature: signature, result: resultString)
                // Stop was pressed while the tool ran: the tool already stopped its processes and
                // returned. Leave the loop now instead of sending its "cancelled" text to the model
                // and paying for another request (and running the remaining tool calls of this step).
                try Task.checkCancellation()
            }

            // send_attachment / write_document return JSON with saved_path.
            // Collect so ViewModel can attach the file as a bubble in the AI message.
            if toolName == "send_attachment" || toolName == "write_document" {
                if let path = parseOutputFilePath(from: resultString) {
                    if !collectedOutputFiles.contains(path) {
                        collectedOutputFiles.append(path)
                        print("[AIOrchestrator] Output file collected via \(toolName): \(path)")
                    }
                }
            }

            // view_image / fetch_attachment (image): tool results can't carry images (providers only accept image_url
            // inside user-role multimodal content). Strip the marker, keep a short text
            // acknowledgment in the tool message, and inject the actual image as a synthetic
            // user message right after — this is the only way the model actually "sees" it.
            if ToolExecutionService.imageResultTools.contains(toolName),
               resultString.hasPrefix(ToolExecutionService.viewImageMarker) {
                let dataURI = String(resultString.dropFirst(ToolExecutionService.viewImageMarker.count))
                sessionHistory.append(AIMessage(
                    role: "tool",
                    content: "Image loaded. Shown to you in the next message for visual inspection.",
                    tool_call_id: toolCall.id,
                    name: toolName
                ))
                sessionHistory.append(AIMessage(role: "user", multimodalParts: [.imageURL(dataURI)]))
                continue
            }

            // read_document / fetch_attachment of an Office file: the text goes back as the tool result,
            // the pictures of the document follow as a user message so the model sees them as images.
            if ToolExecutionService.documentImageTools.contains(toolName),
               let withImages = ToolImageResult.decode(resultString) {
                sessionHistory.append(AIMessage(
                    role: "tool",
                    content: withImages.text,
                    tool_call_id: toolCall.id,
                    name: toolName
                ))
                var parts: [AIMultimodalPart] = [.text("Images contained in the document returned by `\(toolName)` (numbered as in its [image N] markers):")]
                parts.append(contentsOf: withImages.multimodalParts)
                sessionHistory.append(AIMessage(role: "user", multimodalParts: parts))
                continue
            }

            sessionHistory.append(AIMessage(
                role: "tool",
                content: resultString,
                tool_call_id: toolCall.id,
                name: toolName
            ))
        }
    }

    // MARK: - Helpers

    /// Parses the structured JSON response from send_attachment / write_document.
    /// Expected format: {"status":"ok","saved_path":"/absolute/path/file.docx","filename":"..."}
    func parseOutputFilePath(from result: String) -> String? {
        guard let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String, status == "ok",
              let path = json["saved_path"] as? String, !path.isEmpty else {
            return nil
        }
        return path
    }

    func extractTargetPath(from arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return json["path"] as? String ?? ""
    }

    /// Extracts the "command" argument for run_terminal/run_ssh — shown as the live terminal window title.
    func extractCommand(from arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return json["command"] as? String ?? ""
    }
}
