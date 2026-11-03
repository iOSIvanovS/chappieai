// CurlSession.swift
// ChappieCore
//
// In-memory session state of Curl-Chappie. Held by the app-wide engine, never persisted:
// tokens are short-lived and a fresh login after a restart is cheap, whereas persisting them
// would put bearer tokens on disk.
//
// KEY = origin + fingerprint of the login secret VALUES (SHA-256, never stored in clear).
// Two projects that hold the same login/password for the same host share one session
// automatically, and different credentials for the same host never mix. A project that merely
// has a different secret *name* but identical values still lands on the same key.

import Foundation
import CryptoKit

public struct CurlSessionKey: Hashable, Sendable {
    public let origin: String
    public let fingerprint: String

    public static let anonymous = "anonymous"

    public init(origin: String, fingerprint: String) {
        self.origin = origin
        self.fingerprint = fingerprint
    }

    public static func anonymous(origin: String) -> CurlSessionKey {
        CurlSessionKey(origin: origin, fingerprint: anonymous)
    }

    /// Fingerprint of a secret's values; field order does not matter.
    public static func fingerprint(of values: [(field: String, value: String)]) -> String {
        let canonical = values
            .sorted { $0.field < $1.field }
            .map { "\($0.field)\u{1}\($0.value)" }
            .joined(separator: "\u{2}")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

struct CurlVariable: Sendable, Equatable {
    var value: String
    var sensitive: Bool
}

struct CurlLastResponse: Sendable {
    var status: Int
    var headers: [CurlHeader]
    var body: Data
    var cookies: [CurlCookie]
}

struct CurlSession: Sendable {
    var variables: [String: CurlVariable] = [:]
    var cookies: [CurlCookie] = []
    /// Bumped on every successful login. A 401 is answered with a re-login only if the
    /// generation the failed request used is still current; otherwise a neighbour already
    /// refreshed the session and a plain retry is enough (no session is knocked out).
    var generation = 0
    var establishedAt: Date?
    var recipe: CurlLoginRecipe?
    var last: CurlLastResponse?

    func hasAllVariables(of rules: [CurlExtractRule]) -> Bool {
        !rules.isEmpty && rules.allSatisfy { variables[$0.name] != nil }
    }
}
