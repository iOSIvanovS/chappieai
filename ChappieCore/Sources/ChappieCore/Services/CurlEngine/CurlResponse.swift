// CurlResponse.swift
// ChappieCore
//
// The redacted result handed to the model. By the time a CurlResponse exists every known
// secret/token value has already been removed from it.

import Foundation

public struct CurlResponse: Sendable, Equatable {
    public var method: String
    public var url: String
    public var status: Int
    public var headers: [CurlHeader]
    public var cookieNames: [String]
    public var body: String
    public var bodyBytes: Int
    public var truncated: Bool
    public var durationMs: Int
    public var relogin: Bool
    public var notes: [String]

    public func render() -> String {
        var out = "HTTP \(status) \(HTTPURLResponse.localizedString(forStatusCode: status)) — \(method) \(url) — \(durationMs) ms\n"
        if relogin {
            out += "Note: the server answered 401, the session was re-established from the saved recipe and the request was repeated once.\n"
        }
        for note in notes { out += "Note: \(note)\n" }
        if !headers.isEmpty {
            out += "Headers:\n"
            for header in headers { out += "  \(header.name): \(header.value)\n" }
        }
        if !cookieNames.isEmpty {
            out += "Session cookies (values hidden): \(cookieNames.joined(separator: ", "))\n"
        }
        out += "Body (\(bodyBytes) bytes\(truncated ? ", truncated" : "")):\n\(body)"
        return out
    }
}

/// The redacted answer for the model plus the raw one for the scenario runner (never shown).
public struct CurlCapturedResponse: Sendable {
    public var response: CurlResponse
    public var raw: CurlRawResponse
}

public extension CurlLoginSummary {
    func render(sessionLabel: String) -> String {
        if reused {
            return "Session '\(sessionLabel)' is already established (generation \(generation)); no login request was sent. Stored variables: \(storedVariables.isEmpty ? "none" : storedVariables.joined(separator: ", ")). Use force=true to log in again."
        }
        var out = "Login OK (HTTP \(status)), session '\(sessionLabel)' generation \(generation)."
        out += "\nStored variables (values hidden unless marked non-sensitive): \(storedVariables.isEmpty ? "none" : storedVariables.joined(separator: ", "))"
        if !cookieNames.isEmpty { out += "\nCookies: \(cookieNames.joined(separator: ", "))" }
        out += "\nThe session is shared by every project and thread that uses the same credentials for this host."
        return out
    }
}
