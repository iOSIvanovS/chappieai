// LLMRetryTests.swift
// ChappieCoreTests
//
// Backlog 13: one retry system for HTTP errors, network drops, timeouts, stalls and mid-stream cuts.

import Testing
import Foundation
@testable import ChappieCore

// MARK: - Helpers

private actor Counter {
    private(set) var value = 0
    func next() -> Int { value += 1; return value }
}

private actor Log {
    private(set) var items: [String] = []
    func add(_ s: String) { items.append(s) }
}

private final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [RetryStatus?] = []
    func add(_ s: RetryStatus?) { lock.lock(); items.append(s); lock.unlock() }
    var all: [RetryStatus?] { lock.lock(); defer { lock.unlock() }; return items }
}

private func http(_ code: Int, _ message: String = "boom", retryAfter: TimeInterval? = nil) -> ProviderHTTPError {
    ProviderHTTPError(statusCode: code, message: message, retryAfter: retryAfter)
}

private func ok(_ text: String = "done") -> AIStreamResult {
    AIStreamResult(text: text, toolCalls: nil, cost: nil, balance: nil)
}

/// Runner that never really sleeps and records the requested pauses.
private func fastRunner(
    policy: RetryPolicy = .standard,
    sleeps: Log? = nil,
    abort: @escaping @Sendable () async -> Bool = { false }
) -> LLMRetryRunner {
    var runner = LLMRetryRunner(policy: policy)
    runner.sleep = { seconds in await sleeps?.add(String(format: "%.2f", seconds)) }
    runner.random = { 0.5 }          // jitter factor 1.0
    runner.shouldAbort = abort
    return runner
}

private func isRetry(_ failure: LLMFailure) -> Bool {
    if case .retry = failure { return true }
    return false
}

private func isFatal(_ failure: LLMFailure) -> Bool {
    if case .fatal = failure { return true }
    return false
}

// MARK: - Classifier

@Suite("LLMFailureClassifier")
struct LLMFailureClassifierTests {

    @Test("Transient HTTP statuses are retried", arguments: [408, 425, 429, 500, 502, 503, 504, 529, 520])
    func transient(code: Int) {
        #expect(isRetry(LLMFailureClassifier.classify(http(code))))
    }

    @Test("Client errors are not retried", arguments: [400, 401, 402, 403, 404, 422])
    func fatal(code: Int) {
        #expect(isFatal(LLMFailureClassifier.classify(http(code))))
    }

    @Test("429 about billing or quota is fatal, plain 429 is retried")
    func quota429() {
        #expect(isFatal(LLMFailureClassifier.classify(http(429, "You exceeded your current quota"))))
        #expect(isFatal(LLMFailureClassifier.classify(http(429, "Insufficient balance"))))
        #expect(isRetry(LLMFailureClassifier.classify(http(429, "Too many requests"))))
    }

    @Test("429 reports rateLimited and carries Retry-After")
    func rateLimitedReason() {
        guard case .retry(let reason, let after, _) = LLMFailureClassifier.classify(http(429, "slow down", retryAfter: 7)) else {
            Issue.record("expected retry"); return
        }
        #expect(reason == .rateLimited)
        #expect(after == 7)
    }

    @Test("Network-level URLErrors are retried", arguments: [
        URLError.Code.timedOut, .networkConnectionLost, .notConnectedToInternet,
        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed
    ])
    func urlErrors(code: URLError.Code) {
        #expect(isRetry(LLMFailureClassifier.classify(URLError(code))))
    }

    @Test("Cancellation is never retried")
    func cancellation() {
        guard case .cancelled = LLMFailureClassifier.classify(CancellationError()) else { Issue.record("expected cancelled"); return }
        guard case .cancelled = LLMFailureClassifier.classify(URLError(.cancelled)) else { Issue.record("expected cancelled"); return }
        guard case .cancelled = LLMFailureClassifier.classify(ChappieError.cancelled) else { Issue.record("expected cancelled"); return }
    }

    @Test("Context overflow, parsing and file errors are fatal")
    func otherFatal() {
        #expect(isFatal(LLMFailureClassifier.classify(ChappieError.aiContextLimitExceeded)))
        #expect(isFatal(LLMFailureClassifier.classify(ChappieError.parsingError("x"))))
        #expect(isFatal(LLMFailureClassifier.classify(URLError(.badURL))))
    }

    @Test("Stall keeps the partial text")
    func stall() {
        guard case .retry(let reason, _, let partial) = LLMFailureClassifier.classify(StallError(stallSeconds: 300, partialText: "abc")) else {
            Issue.record("expected retry"); return
        }
        #expect(reason == .stall)
        #expect(partial == "abc")
    }

    @Test("Legacy text-based timeout from the non-streaming path is retried")
    func legacyTimeout() {
        #expect(isRetry(LLMFailureClassifier.classify(ChappieError.networkError("Request timed out (300s)."))))
        #expect(isFatal(LLMFailureClassifier.classify(ChappieError.networkError("Request failed: bad certificate"))))
    }

    @Test("In-stream overloaded error is retried, an invalid-request one is not")
    func streamErrors() {
        #expect(isRetry(LLMFailureClassifier.classify(ProviderStreamError(type: "overloaded_error", message: "Overloaded"))))
        #expect(isFatal(LLMFailureClassifier.classify(ProviderStreamError(type: "invalid_request_error", message: "bad"))))
    }

    @Test("Interrupted stream keeps partial text and the retry reason of the underlying error")
    func interrupted() {
        let err = StreamInterruptedError(underlying: URLError(.networkConnectionLost), partialText: "hello")
        guard case .retry(let reason, _, let partial) = LLMFailureClassifier.classify(err) else {
            Issue.record("expected retry"); return
        }
        #expect(reason == .network)
        #expect(partial == "hello")

        let fatal = StreamInterruptedError(underlying: ProviderStreamError(type: "invalid_request_error", message: "x"), partialText: "p")
        #expect(isFatal(LLMFailureClassifier.classify(fatal)))
    }
}

// MARK: - HTTP body handling

@Suite("LLMHTTP")
struct LLMHTTPTests {

    private func response(_ code: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://x.test")!, statusCode: code, httpVersion: nil, headerFields: headers)!
    }

    @Test("Provider message is extracted from a JSON error body")
    func extractsMessage() {
        let body = #"{"error":{"type":"overloaded_error","message":"Model is overloaded"}}"#.data(using: .utf8)
        let err = LLMHTTP.error(for: response(529), body: body) as? ProviderHTTPError
        #expect(err?.statusCode == 529)
        #expect(err?.message == "Model is overloaded")
    }

    @Test("Empty body gives an explicit placeholder")
    func emptyBody() {
        let err = LLMHTTP.error(for: response(500), body: nil) as? ProviderHTTPError
        #expect(err?.message == "No response body")
    }

    @Test("A 400 about context length is a context error, a 429 mentioning limits is not")
    func contextDetection() {
        let ctx = #"{"error":{"message":"maximum context length exceeded"}}"#.data(using: .utf8)
        if let e = LLMHTTP.error(for: response(400), body: ctx) as? ChappieError, case .aiContextLimitExceeded = e {
            // expected
        } else {
            Issue.record("400 with 'context length' must be a context error")
        }

        let rate = #"{"error":{"message":"rate limit on context window requests"}}"#.data(using: .utf8)
        #expect(LLMHTTP.error(for: response(429), body: rate) is ProviderHTTPError)

        // 500 with the word "limit" must stay retryable.
        let limit = #"{"error":{"message":"internal limit"}}"#.data(using: .utf8)
        #expect(LLMHTTP.error(for: response(500), body: limit) is ProviderHTTPError)
    }

    @Test("413 is always a context error")
    func status413() {
        guard let e = LLMHTTP.error(for: response(413), body: nil) as? ChappieError, case .aiContextLimitExceeded = e else {
            Issue.record("expected context error"); return
        }
    }

    @Test("Retry-After accepts seconds and HTTP dates")
    func retryAfterParsing() {
        #expect(LLMHTTP.retryAfter(from: response(429, headers: ["Retry-After": "12"])) == 12)
        #expect(LLMHTTP.retryAfter(from: response(429)) == nil)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = now.addingTimeInterval(30)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let value = LLMHTTP.retryAfter(from: response(503, headers: ["Retry-After": f.string(from: future)]), now: now)
        #expect(value != nil && abs(value! - 30) < 1)
    }

    @Test("SSE error payload is parsed, ordinary chunks are not")
    func streamErrorParsing() {
        let e = ProviderStreamError.parse(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        #expect(e?.type == "overloaded_error")
        #expect(ProviderStreamError.parse(#"{"choices":[{"delta":{"content":"error handling"}}]}"#) == nil)
        #expect(ProviderStreamError.parse(#"{"error":null}"#) == nil)
    }
}

// MARK: - Policy

@Suite("RetryPolicy")
struct RetryPolicyTests {

    @Test("Pauses double: 1, 2, 4, 8, 16 and never exceed the cap")
    func schedule() {
        let p = RetryPolicy(jitterFraction: 0)
        let delays = (1...8).map { p.delay(forRetry: $0, retryAfter: nil, randomUnit: 0.5) }
        #expect(delays == [1, 2, 4, 8, 16, 30, 30, 30])
    }

    @Test("Jitter stays within +/- the configured fraction")
    func jitter() {
        let p = RetryPolicy(jitterFraction: 0.2)
        let low = p.delay(forRetry: 3, retryAfter: nil, randomUnit: 0)
        let high = p.delay(forRetry: 3, retryAfter: nil, randomUnit: 0.999)
        #expect(abs(low - 3.2) < 0.001)
        #expect(abs(high - 4.8) < 0.01)
    }

    @Test("Retry-After raises the pause, but an absurd value is ignored")
    func retryAfter() {
        let p = RetryPolicy(jitterFraction: 0)
        #expect(p.delay(forRetry: 1, retryAfter: 20, randomUnit: 0.5) == 20)
        #expect(p.delay(forRetry: 1, retryAfter: 3600, randomUnit: 0.5) == 1)
        #expect(p.delay(forRetry: 3, retryAfter: 1, randomUnit: 0.5) == 4)
    }
}

// MARK: - Runner

@Suite("LLMRetryRunner")
struct LLMRetryRunnerTests {

    private let history = [AIMessage(role: "user", content: "hi")]

    @Test("500, 500, then success: three attempts, two pauses, result returned")
    func recoversFrom500() async throws {
        let counter = Counter()
        let sleeps = Log()
        let result = try await fastRunner(sleeps: sleeps).run(history: history, onRetry: nil) { _ in
            if await counter.next() <= 2 { throw http(500) }
            return ok("hello")
        }
        #expect(result.text == "hello")
        #expect(await counter.value == 3)
        // Pause 1 = 1 s, pause 2 = 2 s, each slept in 1 s ticks.
        #expect(await sleeps.items == ["1.00", "1.00", "1.00"])
    }

    @Test("Gives up after 5 retries and shows the real provider error")
    func exhausts() async {
        let counter = Counter()
        do {
            _ = try await fastRunner().run(history: history, onRetry: nil) { _ in
                _ = await counter.next()
                throw http(500, "upstream down")
            }
            Issue.record("expected failure")
        } catch let error as ProviderHTTPError {
            #expect(error.message == "upstream down")
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(await counter.value == 6)   // 1 original + 5 retries
    }

    @Test("401 and 400 are not retried")
    func noRetryOnClientErrors() async {
        for code in [401, 400] {
            let counter = Counter()
            do {
                _ = try await fastRunner().run(history: history, onRetry: nil) { _ in
                    _ = await counter.next()
                    throw http(code, "nope")
                }
                Issue.record("expected failure")
            } catch {
                #expect(error is ProviderHTTPError)
            }
            #expect(await counter.value == 1)
        }
    }

    @Test("Stall with partial text: the retry continues the answer and joins the texts")
    func continuesAfterStall() async throws {
        let counter = Counter()
        let seen = Log()
        let result = try await fastRunner().run(history: history, onRetry: nil) { h in
            let n = await counter.next()
            await seen.add("\(h.count)")
            if n == 1 { throw StallError(stallSeconds: 300, partialText: "Part one. ") }
            return ok("Part two.")
        }
        #expect(result.text == "Part one. Part two.")
        // First call: 1 message; retry: + assistant partial + continuation prompt.
        #expect(await seen.items == ["1", "3"])
    }

    @Test("Connection reset mid-answer continues instead of restarting")
    func continuesAfterReset() async throws {
        let counter = Counter()
        let result = try await fastRunner().run(history: history, onRetry: nil) { _ in
            if await counter.next() == 1 {
                throw StreamInterruptedError(underlying: URLError(.networkConnectionLost), partialText: "abc")
            }
            return ok("def")
        }
        #expect(result.text == "abcdef")
    }

    @Test("Slow failures (timeout) stop after the smaller cap with an actionable message")
    func slowFailureCap() async {
        let counter = Counter()
        var runner = fastRunner()
        runner.slowFailureLimit = 2
        runner.contextHint = "Context: 40 messages."
        do {
            _ = try await runner.run(history: history, onRetry: nil) { _ in
                _ = await counter.next()
                throw URLError(.timedOut)
            }
            Issue.record("expected failure")
        } catch let error as ChappieError {
            guard case .networkError(let msg) = error else { Issue.record("wrong case"); return }
            #expect(msg.contains("Context: 40 messages."))
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(await counter.value == 3)   // original + 2 retries
    }

    @Test("Progress resets the retry budget: many cuts of a long answer still complete")
    func progressResetsBudget() async throws {
        let counter = Counter()
        let result = try await fastRunner().run(history: history, onRetry: nil) { _ in
            let n = await counter.next()
            if n <= 8 { throw StallError(stallSeconds: 1, partialText: "\(n)") }
            return ok("!")
        }
        #expect(result.text == "12345678!")
    }

    @Test("Cancellation during a pause stops immediately and is not wrapped")
    func cancelDuringPause() async {
        let counter = Counter()
        var runner = fastRunner()
        runner.sleep = { _ in throw CancellationError() }
        do {
            _ = try await runner.run(history: history, onRetry: nil) { _ in
                _ = await counter.next()
                throw http(500)
            }
            Issue.record("expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await counter.value == 1)
    }

    @Test("An invalidated owner aborts instead of retrying")
    func abortWhenInvalidated() async {
        let counter = Counter()
        do {
            _ = try await fastRunner(abort: { true }).run(history: history, onRetry: nil) { _ in
                _ = await counter.next()
                throw http(503)
            }
            Issue.record("expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await counter.value == 1)
    }

    @Test("The pause is counted from the moment the error arrives, whatever the attempt took")
    func pauseIndependentOfAttemptDuration() async throws {
        let counter = Counter()
        let sleeps = Log()
        _ = try await fastRunner(sleeps: sleeps).run(history: history, onRetry: nil) { _ in
            // A slow failure: the attempt itself takes a while, but the pause must still be ~1 s.
            try await Task.sleep(nanoseconds: 50_000_000)
            if await counter.next() == 1 { throw http(500) }
            return ok()
        }
        #expect(await sleeps.items == ["1.00"])
    }

    @Test("Status updates count down, finish with the re-send moment and clear afterwards")
    func statusReporting() async throws {
        let counter = Counter()
        let statuses = StatusLog()
        var policy = RetryPolicy(jitterFraction: 0)
        policy = RetryPolicy(maxRetries: 5, baseDelay: 3, maxDelay: 30, jitterFraction: 0)
        _ = try await fastRunner(policy: policy).run(history: history, onRetry: { statuses.add($0) }) { _ in
            if await counter.next() == 1 { throw http(500) }
            return ok()
        }
        let all = statuses.all
        let seconds = all.compactMap { $0?.secondsRemaining }
        #expect(seconds == [3, 2, 1, 0])
        #expect(all.first??.reason == .http(500))
        #expect(all.first??.attempt == 1)
        #expect(all.first??.maxAttempts == 5)
        #expect(all.last! == nil)
    }

    @Test("No status is reported when the first attempt succeeds")
    func noStatusOnSuccess() async throws {
        let statuses = StatusLog()
        _ = try await fastRunner().run(history: history, onRetry: { statuses.add($0) }) { _ in ok() }
        #expect(statuses.all.isEmpty)
    }

    @Test("429 honours Retry-After")
    func honoursRetryAfter() async throws {
        let counter = Counter()
        let sleeps = Log()
        _ = try await fastRunner(sleeps: sleeps).run(history: history, onRetry: nil) { _ in
            if await counter.next() == 1 { throw http(429, "slow down", retryAfter: 3) }
            return ok()
        }
        #expect(await sleeps.items == ["1.00", "1.00", "1.00"])
    }
}
