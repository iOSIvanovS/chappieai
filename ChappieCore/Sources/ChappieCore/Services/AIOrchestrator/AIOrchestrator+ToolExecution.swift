import Foundation

extension AIOrchestrator {

    // MARK: - Tool Execution

    func executeToolCalls(
        _ toolCalls: [AIToolCall],
        sessionHistory: inout [AIMessage],
        lastToolSignature: inout String?,
        collectedOutputFiles: inout [String],
        overrideToolPermissions: ToolPermissions?,
        onToolCall: @Sendable (String, String) -> Void
    ) async throws {
        for toolCall in toolCalls {
            let toolName = toolCall.function.name
            let arguments = toolCall.function.arguments
            let targetPath = extractTargetPath(from: arguments)
            let signature = "\(toolName)|\(arguments)"
            let resultString: String

            if lastToolSignature == signature {
                // Identical call twice in a row = infinite loop guard.
                resultString = """
                SYSTEM ERROR: You just called `\(toolName)` with the exact same arguments right before this. \
                This is an infinite loop. DO NOT REPEAT THE SAME ACTION. USE A DIFFERENT APPROACH.
                """
                print("[AIOrchestrator] Loop detected: \(toolName) called twice in a row with same args")
            } else if let permissions = overrideToolPermissions {
                let access = ToolAccessController.check(toolName: toolName, permissions: permissions)
                if case .denied = access {
                    resultString = access.denialJSON(toolName: toolName)
                    print("[AIOrchestrator] V2 access denied for '\(toolName)'")
                } else {
                    lastToolSignature = signature
                    onToolCall(toolName, targetPath)
                    resultString = await toolService.execute(call: toolCall)
                }
            } else {
                lastToolSignature = signature
                onToolCall(toolName, targetPath)
                resultString = await toolService.execute(call: toolCall)
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
}
