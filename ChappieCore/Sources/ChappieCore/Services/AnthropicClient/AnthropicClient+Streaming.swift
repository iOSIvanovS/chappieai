// AnthropicClient+Streaming.swift
// ChappieCore
//
// SSE streaming logic for AnthropicClient.
// Handles content_block_start/delta, message_delta, stall watchdog.
//
// PRICE TIMING: the billing id arrives in the response headers, but the price is only final
// after the stream ends, so resolveCost runs after the loop and the result is attached to the
// returned AIStreamResult. A failed lookup yields nil and no error.

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

        let anthropicMessages = applyingCacheBreakpoints(
            to: buildAnthropicMessages(from: chatHistory)
        )
        let anthropicTools = tools.isEmpty ? nil : tools.map(convertTool)

        let body = AnthropicRequest(
            model: modelName,
            maxTokens: maxTokens,
            system: buildSystemBlocks(systemPrompt),
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

        /// Captured before the stream is consumed — the header belongs to the response, not the body.
        let generation = generationId(from: response)

        final class StreamState: @unchecked Sendable {
            var accumulatedText = ""
            var toolBlocks: [Int: (id: String, name: String, inputJSON: String)] = [:]
            var finalBalance: Double? = nil
            var usage: AnthropicUsage? = nil
            var finishReason: String? = nil
            var chunks = 0
            var skippedChunks = 0
            var firstSkippedSample: String? = nil
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
                    state.skippedChunks += 1
                    if state.firstSkippedSample == nil { state.firstSkippedSample = String(jsonString.prefix(200)) }
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
                        // Kept until the end: the price arrives after the stream, so the single
                        // CACHE line can report tokens and cost together, like the OpenAI route.
                        state.usage = usage
                        state.finalBalance = usage.balance
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

        var diagnostics = StreamDiagnostics()
        diagnostics.recordNative(
            finishReason: state.finishReason,
            chunks: state.chunks,
            skippedChunks: state.skippedChunks,
            firstSkippedSample: state.firstSkippedSample
        )
        print(diagnostics.summary(
            textChars: state.accumulatedText.count,
            structuredToolCalls: toolCalls?.count ?? 0,
            textHasToolMarker: StreamDiagnostics.containsFlattenedToolMarker(state.accumulatedText),
            host: endpointURL.host ?? "",
            model: modelName
        ))

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
            skippedChunks: state.skippedChunks,
            firstSkippedSample: state.firstSkippedSample,
            text: state.accumulatedText,
            toolCalls: (toolCalls ?? []).map {
                StreamDumpToolCall(name: $0.function.name, arguments: $0.function.arguments)
            }
        )
        if let reason = StreamDumpRecorder.reason(for: dumpSummary, forced: StreamDumpRecorder.isForced) {
            StreamDumpWriter.write(recorder: state.dump, summary: dumpSummary, reason: reason)
        }

        // Price and balance are resolved after the stream so the header is already available and
        // the amount is final. Both are best-effort: nil keeps the previous value in the UI.
        let cost = try await resolveCost(generationId: generation)
        let balance: Double?
        if let reported = state.finalBalance {
            balance = reported
        } else {
            balance = await fetchBalance()
        }

        logCacheStats(
            inputTokens: state.usage?.inputTokens ?? 0,
            outputTokens: state.usage?.outputTokens ?? 0,
            cacheRead: state.usage?.cacheReadInputTokens ?? 0,
            cacheCreation: state.usage?.cacheCreationInputTokens ?? 0,
            cost: cost,
            balance: balance
        )
        print("[RequestTrace] \(LogClock.stamp()) RESPONSE anthropic"
              + " | read \(state.usage?.cacheReadInputTokens ?? 0)"
              + " | wrote \(state.usage?.cacheCreationInputTokens ?? 0)"
              + " | fresh \(state.usage?.inputTokens ?? 0)"
              + " | out \(state.usage?.outputTokens ?? 0)"
              + " | finish \(state.finishReason ?? "none")")

        return AIStreamResult(
            text: state.accumulatedText,
            toolCalls: toolCalls,
            cost: cost,
            balance: balance
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
        let total = inputTokens + cacheRead + cacheCreation

        if cacheRead > 0 {
            let pct = total > 0 ? Int(Double(cacheRead) / Double(total) * 100) : 0
            print("[AnthropicClient] CACHE HIT | prompt: \(total) | read: \(cacheRead) (\(pct)%) | created: \(cacheCreation) | completion: \(outputTokens) | cost: \(costStr) | balance: \(balanceStr)")
        } else if cacheCreation > 0 {
            print("[AnthropicClient] CACHE WRITE | prompt: \(total) | created: \(cacheCreation) | completion: \(outputTokens) | cost: \(costStr) | balance: \(balanceStr)")
        } else {
            print("[AnthropicClient] CACHE MISS | prompt: \(total) | completion: \(outputTokens) | cost: \(costStr) | balance: \(balanceStr)")
        }
    }
}
