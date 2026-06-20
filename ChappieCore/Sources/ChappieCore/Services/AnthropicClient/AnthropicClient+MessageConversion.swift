// AnthropicClient+MessageConversion.swift
// ChappieCore
//
// Converts AIMessage/AITool (shared protocol types) into Anthropic wire format.
// Key differences from OpenAI: tool results go as "user" role, tool calls as content blocks.

import Foundation

extension AnthropicClient {

    // MARK: - Message Conversion

    func buildAnthropicMessages(from history: [AIMessage]) -> [AnthropicMessage] {
        var result: [AnthropicMessage] = []

        for msg in history {
            switch msg.role {
            case "system":
                continue

            case "tool":
                let toolResult = AnthropicToolResultContent(
                    type: "tool_result",
                    toolUseId: msg.tool_call_id ?? "",
                    content: msg.contentString ?? ""
                )
                result.append(AnthropicMessage(role: "user", content: .toolResult(toolResult)))

            case "assistant":
                if let toolCalls = msg.tool_calls, !toolCalls.isEmpty {
                    var blocks: [AnthropicContentBlock] = []
                    if let text = msg.contentString, !text.isEmpty {
                        blocks.append(AnthropicContentBlock(type: "text", text: text))
                    }
                    for call in toolCalls {
                        let inputData = call.function.arguments.data(using: .utf8) ?? Data()
                        let inputJSON = (try? JSONSerialization.jsonObject(with: inputData)) ?? [String: Any]()
                        blocks.append(AnthropicContentBlock(
                            type: "tool_use",
                            id: call.id,
                            name: call.function.name,
                            input: inputJSON as? [String: Any]
                        ))
                    }
                    result.append(AnthropicMessage(role: "assistant", content: .blocks(blocks)))
                } else {
                    result.append(AnthropicMessage(role: "assistant", content: .text(msg.contentString ?? "")))
                }

            default:
                switch msg.content {
                case .multimodal(let parts):
                    let blocks = parts.compactMap { part -> AnthropicContentBlock? in
                        switch part {
                        case .text(let t):
                            return AnthropicContentBlock(type: "text", text: t)
                        case .imageURL(let url):
                            guard url.hasPrefix("data:") else { return nil }
                            let withoutData = String(url.dropFirst(5))
                            guard let semicolon = withoutData.firstIndex(of: ";"),
                                  let comma = withoutData.firstIndex(of: ",") else { return nil }
                            let mediaType = String(withoutData[withoutData.startIndex..<semicolon])
                            let base64Data = String(withoutData[withoutData.index(after: comma)...])
                            return AnthropicContentBlock(
                                type: "image",
                                source: AnthropicImageSource(type: "base64", mediaType: mediaType, data: base64Data)
                            )
                        }
                    }
                    result.append(AnthropicMessage(role: "user", content: .blocks(blocks)))
                default:
                    result.append(AnthropicMessage(role: "user", content: .text(msg.contentString ?? "")))
                }
            }
        }

        return mergeConsecutiveSameRole(result)
    }

    /// Anthropic rejects requests where two consecutive messages share the same role.
    func mergeConsecutiveSameRole(_ messages: [AnthropicMessage]) -> [AnthropicMessage] {
        var merged: [AnthropicMessage] = []
        for msg in messages {
            if let last = merged.last, last.role == msg.role {
                let combined = [last.contentString ?? "", msg.contentString ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: "\n\n")
                merged[merged.count - 1] = AnthropicMessage(role: last.role, content: .text(combined))
            } else {
                merged.append(msg)
            }
        }
        return merged
    }

    // MARK: - Tool Conversion

    func convertTool(_ tool: AITool) -> AnthropicTool {
        let props = tool.function.parameters.properties.mapValues { prop in
            AnthropicToolProperty(type: prop.type, description: prop.description)
        }
        return AnthropicTool(
            name: tool.function.name,
            description: tool.function.description,
            inputSchema: AnthropicToolInputSchema(
                type: "object",
                properties: props,
                required: tool.function.parameters.required
            )
        )
    }
}
