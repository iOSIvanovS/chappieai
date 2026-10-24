// LLMFailureClassifier.swift
// ChappieCore
//
// Decides what to do with an error from an LLM request: retry (and why), give up, or stop.
// One place for every failure kind — HTTP, network, timeout, stall, mid-stream drop.

import Foundation

// MARK: - RetryReason

/// Why a request is being retried. The UI turns this into a localized label.
public enum RetryReason: Sendable, Equatable {
    case http(Int)
    case rateLimited
    case network
    case timeout
    case stall
}

// MARK: - LLMFailure

enum LLMFailure: Sendable {
    /// Transient problem. `partialText` is whatever the user already saw before the failure.
    case retry(reason: RetryReason, retryAfter: TimeInterval?, partialText: String)
    /// Retrying cannot help (bad request, auth, billing, context overflow, parsing).
    case fatal
    /// User cancelled — never retried, never wrapped.
    case cancelled
}

// MARK: - Classifier

enum LLMFailureClassifier {

    /// HTTP statuses where waiting and re-sending is the right answer.
    private static let transientStatuses: Set<Int> = [408, 425, 429, 500, 502, 503, 504, 529]

    private static let transientStreamErrorTypes: Set<String> = [
        "overloaded_error", "api_error", "rate_limit_error", "server_error", "timeout", "service_unavailable"
    ]

    static func classify(_ error: Error) -> LLMFailure {
        if error is CancellationError { return .cancelled }

        if let stall = error as? StallError {
            return .retry(reason: .stall, retryAfter: nil, partialText: stall.partialText)
        }

        if let interrupted = error as? StreamInterruptedError {
            switch classify(interrupted.underlying) {
            case .retry(let reason, let retryAfter, _):
                return .retry(reason: reason, retryAfter: retryAfter, partialText: interrupted.partialText)
            case .fatal, .cancelled:
                return .fatal
            }
        }

        if let http = error as? ProviderHTTPError { return classifyHTTP(http) }

        if let streamError = error as? ProviderStreamError { return classifyStream(streamError) }

        if let urlError = error as? URLError { return classifyURLError(urlError) }

        if let chappie = error as? ChappieError {
            switch chappie {
            case .cancelled:
                return .cancelled
            case .networkError(let message):
                // Legacy text-based timeouts from the non-streaming path.
                let lower = message.lowercased()
                if lower.contains("timed out") || lower.contains("timeout") || lower.contains("time out") {
                    return .retry(reason: .timeout, retryAfter: nil, partialText: "")
                }
                return .fatal
            default:
                return .fatal
            }
        }

        return .fatal
    }

    // MARK: - HTTP

    private static func classifyHTTP(_ error: ProviderHTTPError) -> LLMFailure {
        let status = error.statusCode
        let lower = error.message.lowercased()

        // Out of money / quota is a 429 for some providers — waiting will not fix it.
        if status == 429, lower.contains("insufficient") || lower.contains("quota") || lower.contains("billing") {
            return .fatal
        }
        guard transientStatuses.contains(status) || (500...599).contains(status) else { return .fatal }

        let reason: RetryReason = status == 429 ? .rateLimited : .http(status)
        return .retry(reason: reason, retryAfter: error.retryAfter, partialText: "")
    }

    // MARK: - SSE error event

    private static func classifyStream(_ error: ProviderStreamError) -> LLMFailure {
        let type = error.type?.lowercased() ?? ""
        let message = error.message.lowercased()
        let transient = transientStreamErrorTypes.contains(type)
            || message.contains("overloaded")
            || message.contains("try again")
        guard transient else { return .fatal }
        let reason: RetryReason = type.contains("rate_limit") ? .rateLimited : .http(529)
        return .retry(reason: reason, retryAfter: nil, partialText: "")
    }

    // MARK: - URLError

    private static func classifyURLError(_ error: URLError) -> LLMFailure {
        switch error.code {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .retry(reason: .timeout, retryAfter: nil, partialText: "")
        case .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed,
             .dataNotAllowed, .internationalRoamingOff, .callIsActive, .cannotLoadFromNetwork:
            return .retry(reason: .network, retryAfter: nil, partialText: "")
        default:
            return .fatal
        }
    }
}
