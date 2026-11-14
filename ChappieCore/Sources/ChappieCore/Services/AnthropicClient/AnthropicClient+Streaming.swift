// AnthropicClient+Streaming.swift
// ChappieCore
//
// SSE streaming logic for AnthropicClient.
// Handles content_block_start/delta, message_delta, stall watchdog.

import Foundation

extension AnthropicClient {

    // MARK: - AIClientProtocol: streamRequestWithTools

    public func streamRequestWithTools(
        systemPrompt: String,
        chatHistory: [AIMessage],
        tools: [AITool],
        stallTimeout: TimeInterval = AppConfig.shared.stallTimeoutSeconds,
        onToken: (@Sendable (String) -> Void)? = nil
    ) async throws -> AIStreamResult {

        try Task.checkCancellation()

        let anthropicMessages = buildAnthropicMessages(from: chatHistory)
        let anthropicTools = tools.isEmpty ? nil : tools.map(convertTool)

        let body = AnthropicRequest(
            model: modelName,
            maxTokens: Self.maxTokens,
            system: systemPrompt.isEmpty ? nil : systemPrompt,
            messages: anthropicMessages,
            tools: anthropicTools,
            stream: true
        )

        print("[AnthropicClient] Request: \(anthropicMessages.count) messages → \(endpointURL.host ?? "") / \(modelName)")

        let request = try buildRequest(body: body)

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
        let errorBody = await LLMHTTP.errorBodyIfNeeded(response, bytes: asyncBytes)
        try validateHTTPResponse(response, data: errorBody)

        final class StreamState: @unchecked Sendable {
            var accumulatedText = ""
            var toolBlocks: [Int: (id: String, name: String, inputJSON: String)] = [:]
            var finalCost: Double? = nil
            var finalBalance: Double? = nil
            var finishReason: String? = nil
            var chunks = 0
            /// Raw SSE lines, kept in memory and written only when the stream looks wrong.
            var dump = StreamDumpRecorder()
        }
        let state = StreamState()
        let watchdog = StallWatchdog(timeout: stallTimeout)

        let streamTask = Task {
            await watchdog.start()

            for try await line in asyncBytes.lines {
                if Task.isCancelled { break }
                await watchdog.reset()

                if line.hasPrefix("event: ") {
                    state.dump.record(line)
                    continue
                }
                guard line.hasPrefix("data: ") else { continue }
                let jsonString = String(line.dropFirst(6))
                state.dump.record(line)
                guard !jsonString.isEmpty else { continue }

                // `event: error` (e.g. overloaded_error) arrives inside a 200 stream.
                if jsonString.contains("\"error\""), let streamError = ProviderStreamError.parse(jsonString) {
                    throw streamError
                }

                guard let data = jsonString.data(using: .utf8),
                      let json = try? JSONDecoder().decode(AnthropicStreamEvent.self, from: data) else {
                    continue
                }

                state.chunks += 1
                switch json.type {
                case "content_block_start":
                    if let block = json.contentBlock, block.type == "tool_use" {
                        let idx = json.index ?? 0
                        state.toolBlocks[idx] = (id: block.id ?? "call_\(idx)", name: block.name ?? "", inputJSON: "")
                    }

                case "content_block_delta":
                    let idx = json.index ?? 0
                    if let delta = json.delta {
                        switch delta.type {
                        case "text_delta":
                            if let text = delta.text, !text.isEmpty {
                                state.accumulatedText += text
                                onToken?(text)
                            }
                        case "input_json_delta":
                            if let partial = delta.partialJSON, var existing = state.toolBlocks[idx] {
                                existing.inputJSON += partial
                                state.toolBlocks[idx] = existing
                            }
                        default: break
                        }
                    }

                case "message_delta":
                    if let reason = json.delta?.stopReason, !reason.isEmpty { state.finishReason = reason }
                    if let usage = json.usage {
                        state.finalCost = usage.costRub
                        state.finalBalance = usage.balance
                        logCacheStats(
                            inputTokens: usage.inputTokens ?? 0,
                            outputTokens: usage.outputTokens ?? 0,
                            cacheRead: usage.cacheReadInputTokens ?? 0,
                            cacheCreation: usage.cacheCreationInputTokens ?? 0,
                            cost: usage.costRub,
                            balance: usage.balance
                        )
                    }

                default: break
                }
            }

            await watchdog.stop()
        }

        do {
            try await streamTask.value
        } catch is CancellationError {
            if await watchdog.isStalled {
                throw StallError(stallSeconds: stallTimeout, partialText: state.accumulatedText)
            }
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            if await watchdog.isStalled {
                throw StallError(stallSeconds: stallTimeout, partialText: state.accumulatedText)
            }
            throw ChappieError.cancelled
        } catch {
            if state.accumulatedText.isEmpty || !state.toolBlocks.isEmpty { throw error }
            throw StreamInterruptedError(underlying: error, partialText: state.accumulatedText)
        }

        let toolCalls: [AIToolCall]? = state.toolBlocks.isEmpty ? nil :
            state.toolBlocks.sorted(by: { $0.key < $1.key }).compactMap { (_, block) in
                guard !block.name.isEmpty else { return nil }
                return AIToolCall(
                    id: block.id,
                    type: "function",
                    function: AIToolCallFunction(name: block.name, arguments: block.inputJSON)
                )
            }

        let dumpSummary = StreamDumpSummary(
            date: Date(),
            host: endpointURL.host ?? "",
            path: endpointURL.path,
            protocolName: "anthropic",
            model: modelName,
            upstreamModel: nil,
            upstreamProvider: nil,
            finishReason: state.finishReason,
            chunks: state.chunks,
            skippedChunks: 0,
            firstSkippedSample: nil,
            text: state.accumulatedText,
            toolCalls: (toolCalls ?? []).map {
                StreamDumpToolCall(name: $0.function.name, arguments: $0.function.arguments)
            }
        )
        if let reason = StreamDumpRecorder.reason(for: dumpSummary, forced: StreamDumpRecorder.isForced) {
            StreamDumpWriter.write(recorder: state.dump, summary: dumpSummary, reason: reason)
        }

        return AIStreamResult(
            text: state.accumulatedText,
            toolCalls: toolCalls,
            cost: state.finalCost,
            balance: state.finalBalance
        )
    }

    // MARK: - Cache Stats Logging

    func logCacheStats(
        inputTokens: Int,
        outputTokens: Int,
        cacheRead: Int,
        cacheCreation: Int,
        cost: Double?,
        balance: Double?
    ) {
        let costStr = cost.map { String(format: "%.4f RUB", $0) } ?? "n/a"
        let balanceStr = balance.map { String(format: "%.2f RUB", $0) } ?? "n/a"

        if cacheRead > 0 {
            let pct = inputTokens > 0 ? Int(Double(cacheRead) / Double(inputTokens) * 100) : 0
            print("[AnthropicClient] CACHE HIT | input: \(inputTokens) | read: \(cacheRead) (\(pct)%) | created: \(cacheCreation) | output: \(outputTokens) | cost: \(costStr) | balance: \(balanceStr)")
        } else if cacheCreation > 0 {
            print("[AnthropicClient] CACHE WRITE | input: \(inputTokens) | created: \(cacheCreation) | output: \(outputTokens) | cost: \(costStr) | balance: \(balanceStr)")
        } else {
            print("[AnthropicClient] CACHE MISS | input: \(inputTokens) | output: \(outputTokens) | cost: \(costStr) | balance: \(balanceStr)")
        }
    }
}
