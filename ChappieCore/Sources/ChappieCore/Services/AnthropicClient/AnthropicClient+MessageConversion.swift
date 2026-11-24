// AnthropicClient+MessageConversion.swift
// ChappieCore
//
// Converts AIMessage/AITool (shared protocol types) into Anthropic wire format.
// Key differences from OpenAI: tool results go as "user" role, tool calls as content blocks.
//
// MERGING (why it is block-level):
// Anthropic rejects two consecutive messages with the same role, so adjacent same-role messages
// are merged. Merging must keep content BLOCKS, not text: turning a tool_result into plain text
// drops its tool_use_id, and the model then cannot tell which call the output belongs to.
// Verified: a merged-by-text history makes the model answer "I don't know what you asked" while
// returning HTTP 200 — a silent wrong answer, not an error.

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

            case ScreenFrame.role:
                // The live screen, sent last and marked, so applyingCacheBreakpoints can keep it
                // out of the cached prefix. Merged into the preceding user turn like any other.
                let blocks = (msg.multimodalParts ?? []).compactMap(block(from:)).map { block in
                    var marked = block
                    marked.isScreenFrame = true
                    return marked
                }
                result.append(AnthropicMessage(role: "user", content: .blocks(blocks)))

            default:
                switch msg.content {
                case .multimodal(let parts):
                    result.append(AnthropicMessage(
                        role: "user",
                        content: .blocks(parts.compactMap(block(from:)))
                    ))
                default:
                    result.append(AnthropicMessage(role: "user", content: .text(msg.contentString ?? "")))
                }
            }
        }

        return mergeConsecutiveSameRole(result)
    }

    /// One multimodal part as a wire block. A picture must be a data: URI — anything else (a
    /// remote URL the provider would have to fetch) is dropped rather than sent and rejected.
    func block(from part: AIMultimodalPart) -> AnthropicContentBlock? {
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

    /// Anthropic rejects requests where two consecutive messages share the same role.
    /// Blocks are concatenated as they are — a tool_result keeps its tool_use_id.
    func mergeConsecutiveSameRole(_ messages: [AnthropicMessage]) -> [AnthropicMessage] {
        var merged: [AnthropicMessage] = []
        for msg in messages {
            if let last = merged.last, last.role == msg.role {
                merged[merged.count - 1] = AnthropicMessage(
                    role: last.role,
                    content: .blocks(last.content.asBlocks() + msg.content.asBlocks())
                )
            } else {
                merged.append(msg)
            }
        }
        return merged
    }

    // MARK: - Prompt Caching

    /// Places cache breakpoints on the request: one at the end of the system prompt, one at the
    /// last block of the last message that belongs to the prefix.
    ///
    /// WHY THESE TWO PLACES: a breakpoint marks "everything up to here is cacheable". The system
    /// prompt never changes, and history grows by appending, so the tail of this request becomes a
    /// prefix of the next one — each request reads the previous prefix and writes only the delta.
    /// The one exception is the live screen frame, which is deliberately left after the breakpoint
    /// (see ScreenFrame): it is the only part of the request that changes on every computer step.
    ///
    /// WHY NOT A TOP-LEVEL cache_control: measured on RouterAI's native endpoint over five growing
    /// requests, top-level wrote the full prefix every time and read nothing back
    /// (write ≈17k, read 0 on every turn). With explicit block breakpoints the same series gave
    /// read growing 16891 → 16980 and write never above 18 tokens.
    ///
    /// Returns the messages unchanged when caching is off, so strict providers see no new fields.
    func applyingCacheBreakpoints(to messages: [AnthropicMessage]) -> [AnthropicMessage] {
        guard supportsCaching, var last = messages.last else { return messages }

        switch last.content {
        case .text(let text):
            last.content = .blocks([
                AnthropicContentBlock(type: "text", text: text, cacheControl: Self.cacheControl)
            ])

        case .blocks(let blocks):
            // The breakpoint goes on the last block that belongs to the PREFIX. The live screen
            // frame sits at the very end of every computer-use request and changes on each step,
            // so a breakpoint after it would put it inside the cache and force a rewrite of the
            // whole prefix every time. Everything after the breakpoint is simply not cached.
            guard let index = blocks.lastIndex(where: { !$0.isScreenFrame }) else { return messages }
            var marked = blocks
            marked[index].cacheControl = Self.cacheControl
            last.content = .blocks(marked)

        case .toolResult(var result):
            // The struct is encoded as a one-element array; the breakpoint goes inside it.
            result.cacheControl = Self.cacheControl
            last.content = .toolResult(result)
        }

        var out = messages
        out[out.count - 1] = last
        return out
    }

    /// Builds the system field. Blocks are used instead of a bare string so a breakpoint can be
    /// attached; without caching it stays a plain string to keep strict providers happy.
    func buildSystemBlocks(_ systemPrompt: String) -> [AnthropicSystemBlock]? {
        guard !systemPrompt.isEmpty else { return nil }
        return [AnthropicSystemBlock(
            text: systemPrompt,
            cacheControl: supportsCaching ? Self.cacheControl : nil
        )]
    }

    // MARK: - Tool Conversion

    func convertTool(_ tool: AITool) -> AnthropicTool {
        let props = tool.function.parameters.properties.mapValues(convertProperty)
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

    private func convertProperty(_ prop: AIToolProperty) -> AnthropicToolProperty {
        AnthropicToolProperty(
            type: prop.type,
            description: prop.description,
            items: prop.items.map(convertShape)
        )
    }

    /// Array and object arguments need their inner shape, so the model knows what an element looks
    /// like; a bare "array" leaves it guessing and a strict schema rejects an array without items.
    private func convertShape(_ shape: AIToolItemShape) -> AnthropicToolProperty {
        AnthropicToolProperty(
            type: shape.type,
            description: shape.description,
            items: shape.items.map(convertShape)
        )
    }
}
