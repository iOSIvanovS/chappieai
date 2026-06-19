// AIClient+Streaming.swift — streamRequestWithTools implementation
import Foundation

extension AIClient {

    public func streamRequestWithTools(
        systemPrompt: String,
        chatHistory: [AIMessage],
        tools: [AITool],
        stallTimeout: TimeInterval = AppConfig.shared.stallTimeoutSeconds,
        onToken: (@Sendable (String) -> Void)? = nil
    ) async throws -> AIStreamResult {

        try Task.checkCancellation()

        let messages = buildMessages(systemPrompt: systemPrompt, chatHistory: chatHistory)
        let body = AITunnelRequest(
            model: modelName,
            messages: messages,
            temperature: 0.7,
            tools: tools.isEmpty ? nil : tools,
            stream: true,
            // AITunnel (Anthropic): top-level cache_control caches everything automatically —
            // system prompt, full chat history, and all tool results in one shot.
            // Anthropic slides the breakpoint forward as the dialogue grows.
            // Other providers: supportsCaching=false → cacheControl=nil, no effect.
            cacheControl: supportsCaching ? .oneHour : nil
        )

        let request = try buildURLRequest(body: body)

        let asyncBytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (asyncBytes, response) = try await urlSession.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw ChappieError.cancelled
        }

        try Task.checkCancellation()
        try validateHTTPResponse(response, data: nil)

        final class StreamState: @unchecked Sendable {
            var accumulatedText = ""
            var toolCallBuffers: [Int: (id: String, name: String, arguments: String)] = [:]
            var finalCost: Double? = nil
            var finalBalance: Double? = nil
        }
        let state = StreamState()
        let watchdog = StallWatchdog(timeout: stallTimeout)

        let streamTask = Task {
            await watchdog.start()

            for try await line in asyncBytes.lines {
                if Task.isCancelled { break }
                await watchdog.reset()

                guard !line.isEmpty, line.hasPrefix("data: ") else { continue }
                let jsonString = String(line.dropFirst(6))
                if jsonString == "[DONE]" { break }

                guard let chunkData = jsonString.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(AIStreamChunk.self, from: chunkData) else {
                    continue
                }

                if let usage = chunk.usage {
                    state.finalCost = usage.cost_rub
                    state.finalBalance = usage.balance
                    logCacheStats(usage: usage)
                }

                guard let choice = chunk.choices.first else { continue }
                let delta = choice.delta

                if let token = delta.content, !token.isEmpty {
                    state.accumulatedText += token
                    onToken?(token)
                }

                if let streamToolCalls = delta.tool_calls {
                    for tc in streamToolCalls {
                        let idx = tc.index
                        if var existing = state.toolCallBuffers[idx] {
                            if let arg = tc.function?.arguments {
                                existing.arguments += arg
                                state.toolCallBuffers[idx] = existing
                            }
                        } else {
                            state.toolCallBuffers[idx] = (
                                id: tc.id ?? "call_\(idx)",
                                name: tc.function?.name ?? "",
                                arguments: tc.function?.arguments ?? ""
                            )
                        }
                    }
                }
            }

            await watchdog.stop()
        }

        do {
            try await streamTask.value
        } catch is CancellationError {
            if await watchdog.isStalled {
                print("[AIClient] Stall after \(stallTimeout)s. Partial: \(state.accumulatedText.count) chars.")
                throw StallError(stallSeconds: stallTimeout, partialText: state.accumulatedText)
            }
            print("[AIClient] Stream cancelled by user.")
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            if await watchdog.isStalled {
                throw StallError(stallSeconds: stallTimeout, partialText: state.accumulatedText)
            }
            throw ChappieError.cancelled
        } catch {
            throw error
        }

        let assembledToolCalls: [AIToolCall]? = state.toolCallBuffers.isEmpty ? nil :
            state.toolCallBuffers.sorted(by: { $0.key < $1.key }).compactMap { (_, buf) in
                guard !buf.name.isEmpty else { return nil }
                return AIToolCall(
                    id: buf.id,
                    type: "function",
                    function: AIToolCallFunction(name: buf.name, arguments: buf.arguments)
                )
            }

        return AIStreamResult(
            text: state.accumulatedText,
            toolCalls: assembledToolCalls,
            cost: state.finalCost,
            balance: state.finalBalance
        )
    }
}
