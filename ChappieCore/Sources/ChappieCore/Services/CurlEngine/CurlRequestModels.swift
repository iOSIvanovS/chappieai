// CurlRequestModels.swift
// ChappieCore
//
// Value types exchanged between the tool layer and the Curl-Chappie engine.

import Foundation

public struct CurlHeader: Sendable, Equatable {
    public var name: String
    public var value: String
    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

public struct CurlPair: Sendable, Equatable {
    public var name: String
    public var value: String
    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

public enum CurlBody: Sendable, Equatable {
    /// Raw JSON text; substituted values are JSON-escaped.
    case json(String)
    /// Ordered pairs, encoded as application/x-www-form-urlencoded after substitution.
    case form([CurlPair])
    case text(String, contentType: String)
}

public struct CurlRequestSpec: Sendable, Equatable {
    public var method: String
    /// Absolute URL; may contain {{...}} placeholders outside the scheme and host.
    public var url: String
    public var headers: [CurlHeader]
    public var query: [CurlPair]
    public var body: CurlBody?
    /// Name of the secret this request acts as ("as"). nil = anonymous scratch session.
    public var session: String?
    /// JSON paths to keep in the shown body (`data.items[*].id`); empty = the whole body.
    /// Applied after redaction, only to what the model sees: the stored last response stays whole.
    public var pick: [String]
    /// false (default) = routine headers (CORS, cache, date, server...) are folded into a count.
    public var showAllHeaders: Bool

    public init(
        method: String,
        url: String,
        headers: [CurlHeader] = [],
        query: [CurlPair] = [],
        body: CurlBody? = nil,
        session: String? = nil,
        pick: [String] = [],
        showAllHeaders: Bool = false
    ) {
        self.showAllHeaders = showAllHeaders
        self.method = method
        self.url = url
        self.headers = headers
        self.query = query
        self.body = body
        self.session = session
        self.pick = pick
    }
}

// MARK: - Login recipe

public enum CurlExtractSource: Sendable, Equatable {
    /// Dotted path with array indexes: "data.user.id", "items[0].token", "$.access_token".
    case json(String)
    case header(String)
    case cookie(String)
}

public struct CurlExtractRule: Sendable, Equatable {
    public var name: String
    public var source: CurlExtractSource
    /// Sensitive values are never shown and are masked in every later response.
    public var sensitive: Bool

    public init(name: String, source: CurlExtractSource, sensitive: Bool = true) {
        self.name = name
        self.source = source
        self.sensitive = sensitive
    }
}

/// Header added to every request of the session, e.g. Authorization = "{{var:token_type}} {{var:access_token}}".
public struct CurlApplyRule: Sendable, Equatable {
    public var header: String
    public var template: String
    public init(header: String, template: String) {
        self.header = header
        self.template = template
    }
}

public struct CurlLoginRecipe: Sendable, Equatable {
    public var request: CurlRequestSpec
    public var extract: [CurlExtractRule]
    public var apply: [CurlApplyRule]

    public init(request: CurlRequestSpec, extract: [CurlExtractRule], apply: [CurlApplyRule] = []) {
        self.request = request
        self.extract = extract
        self.apply = apply
    }
}

// MARK: - Results

public struct CurlLoginSummary: Sendable, Equatable {
    public var status: Int
    public var storedVariables: [String]
    public var cookieNames: [String]
    public var generation: Int
    /// True when an existing shared session was reused and no login request was sent.
    public var reused: Bool
}

public struct CurlExtracted: Sendable, Equatable {
    public var name: String
    /// nil for sensitive values.
    public var shownValue: String?
}

public struct CurlSessionInfo: Sendable, Equatable {
    public var exists: Bool
    public var generation: Int
    public var variables: [String: Bool]   // name -> sensitive
    public var cookieNames: [String]
    public var establishedAt: Date?
    public var hasRecipe: Bool
}

// MARK: - Errors

public enum CurlError: Error, Equatable, Sendable, LocalizedError {
    case denied(String)
    case invalidRequest(String)
    case unresolved([String])
    case missingSecretValue(secret: String, fields: [String])
    case noSession(String)
    case rateLimited(limit: Int)
    case transport(String)
    case loginFailed(String)

    public var errorDescription: String? {
        switch self {
        case .denied(let m), .invalidRequest(let m), .transport(let m), .loginFailed(let m):
            return m
        case .unresolved(let refs):
            return "Unresolved references: \(refs.joined(separator: ", ")). Secrets must be bound to the request host and addressed as {{secret:name.field}}; variables come from the session (curl_session / curl_extract)."
        case .missingSecretValue(let secret, let fields):
            return "Secret '\(secret)' has no stored value for: \(fields.joined(separator: ", ")). Ask the user to enter it in project settings."
        case .noSession(let m):
            return m
        case .rateLimited(let limit):
            return "Curl-Chappie rate limit reached (\(limit) requests per minute). Wait a little before sending more."
        }
    }
}
