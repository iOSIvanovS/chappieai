// LLMHTTP.swift
// ChappieCore
//
// Typed provider errors and HTTP error-body handling shared by AIClient and AnthropicClient.
//
// WHY: the retry system must tell "provider hiccup, try again" (500/502/503/504/529/429)
// from "your request is wrong" (400/401/403) and "context too long". Before this, every
// non-2xx became a string inside ChappieError.networkError and, for streaming requests,
// the body was never read, so the real provider message was lost ("No response body").

import Foundation

// MARK: - ProviderHTTPError

/// Non-2xx answer from the provider. Keeps the status code so the retry layer can classify it.
struct ProviderHTTPError: Error, LocalizedError, Sendable, Equatable {
    let statusCode: Int
    /// Human-readable provider message (extracted from JSON when possible).
    let message: String
    /// Server-requested pause (Retry-After header), seconds.
    let retryAfter: TimeInterval?

    // Same prefix as ChappieError.networkError so existing UI text stays familiar.
    var errorDescription: String? { "Network error: HTTP \(statusCode): \(message)" }
}

// MARK: - ProviderStreamError

/// Error delivered INSIDE an SSE stream after a 200 response
/// (Anthropic `event: error` / `overloaded_error`, OpenAI-style `data: {"error": ...}`).
struct ProviderStreamError: Error, LocalizedError, Sendable, Equatable {
    let type: String?
    let message: String

    var errorDescription: String? { "Provider error: \(message)" }

    /// Parses `{"error": {...}}` / `{"error": "text"}`. Returns nil when the JSON has no error.
    static func parse(_ json: String) -> ProviderStreamError? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["error"], !(raw is NSNull) else { return nil }

        if let text = raw as? String {
            return ProviderStreamError(type: nil, message: text)
        }
        guard let dict = raw as? [String: Any] else { return nil }
        let type = (dict["type"] as? String) ?? (dict["code"] as? String)
        let message = (dict["message"] as? String) ?? "Unknown streaming error"
        return ProviderStreamError(type: type, message: message)
    }
}

// MARK: - StreamInterruptedError

/// A stream died after some text had already been delivered to the user (connection reset,
/// provider error event). Carries the partial text so the retry layer can continue from it.
struct StreamInterruptedError: Error, LocalizedError, Sendable {
    let underlying: Error
    let partialText: String

    var errorDescription: String? { underlying.localizedDescription }
}

// MARK: - LLMHTTP

enum LLMHTTP {

    /// Builds the right error for a non-2xx response.
    /// Context-length problems are only recognised on 400/413/422 — a 429 saying
    /// "rate limit" must NOT be mistaken for a context error (it is retryable).
    static func error(for http: HTTPURLResponse, body: Data?) -> Error {
        let message = providerMessage(from: body)
        if isContextLimit(status: http.statusCode, message: message) {
            return ChappieError.aiContextLimitExceeded
        }
        return ProviderHTTPError(
            statusCode: http.statusCode,
            message: message,
            retryAfter: retryAfter(from: http)
        )
    }

    static func isContextLimit(status: Int, message: String) -> Bool {
        if status == 413 { return true }
        guard status == 400 || status == 422 else { return false }
        let lower = message.lowercased()
        return lower.contains("context")
            || lower.contains("too long")
            || lower.contains("token limit")
            || lower.contains("too many tokens")
    }

    /// Extracts `error.message` / `message` from a JSON body, otherwise the trimmed raw text.
    static func providerMessage(from data: Data?) -> String {
        guard let data, !data.isEmpty,
              let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return "No response body"
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let m = error["message"] as? String, !m.isEmpty {
                return truncated(m)
            }
            if let error = object["error"] as? String, !error.isEmpty { return truncated(error) }
            if let m = object["message"] as? String, !m.isEmpty { return truncated(m) }
        }
        return truncated(text)
    }

    private static func truncated(_ text: String, limit: Int = 500) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    /// Retry-After: either delta-seconds or an HTTP date.
    static func retryAfter(from http: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) { return max(0, seconds) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    /// Reads at most `limit` bytes of an error response body from a streaming request,
    /// giving up after `timeout` seconds so a silent server cannot hold the retry hostage.
    static func readErrorBody(
        _ bytes: URLSession.AsyncBytes,
        limit: Int = 4096,
        timeout: TimeInterval = 5
    ) async -> Data {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                var data = Data()
                do {
                    for try await byte in bytes {
                        data.append(byte)
                        if data.count >= limit { break }
                    }
                } catch {
                    // Partial body is still useful.
                }
                return data
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? Data()
        }
    }

    /// For a non-2xx streaming response, reads the body so validateHTTPResponse can report it.
    static func errorBodyIfNeeded(_ response: URLResponse, bytes: URLSession.AsyncBytes) async -> Data? {
        guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else { return nil }
        return await readErrorBody(bytes)
    }
}
