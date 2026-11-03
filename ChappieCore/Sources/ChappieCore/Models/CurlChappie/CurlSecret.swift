// CurlSecret.swift
// ChappieCore
//
// Project-scoped secret METADATA for Curl-Chappie. The values never live here:
// they are stored in the Keychain (see CurlSecretKeychain) and the model only ever
// refers to them by name, e.g. {{secret:sk_test.password}}.
//
// WHY BOUND TO A HOST ORIGIN:
// Substitution happens only when the request origin equals `hostOrigin` exactly. A dev
// password therefore cannot be sent to prod even if the model makes a mistake — the
// guarantee is structural, not behavioural.
//
// The same `name` may exist for several hosts: (name, hostOrigin) is the identity, so the
// model can write the same reference for dev and prod.

import Foundation

// MARK: - CurlSecretKind

public enum CurlSecretKind: String, Codable, Sendable, CaseIterable {
    /// Two parts: `login` and `password`.
    case loginPassword
    /// Bearer token or API key — one `value`.
    case token
    /// Header name (metadata) plus `value`, e.g. X-Api-Key.
    case customHeader
    /// Any substitution string — client id, salt, tenant. One `value`.
    case plain

    /// Value parts stored in the Keychain for this kind.
    public var fields: [CurlSecretField] {
        switch self {
        case .loginPassword:               return [.login, .password]
        case .token, .customHeader, .plain: return [.value]
        }
    }
}

/// A single Keychain-stored part of a secret. rawValue doubles as the reference suffix
/// ({{secret:name.login}}), so never rename.
public enum CurlSecretField: String, Codable, Sendable, CaseIterable {
    case login, password, value
}

// MARK: - CurlSecret

public struct CurlSecret: Codable, Sendable, Identifiable, Hashable {

    public let id: UUID
    /// Reference name: letters, digits, underscore, dash. See `isValidName`.
    public var name: String
    public var kind: CurlSecretKind
    /// Normalized origin this secret is bound to.
    public var hostOrigin: String
    /// Only for `.customHeader`; empty otherwise.
    public var headerName: String

    public init(
        id: UUID = UUID(),
        name: String,
        kind: CurlSecretKind,
        hostOrigin: String,
        headerName: String = ""
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.hostOrigin = CurlOrigin.normalize(hostOrigin) ?? hostOrigin
        self.headerName = headerName
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, hostOrigin, headerName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = (try? c.decodeIfPresent(CurlSecretKind.self, forKey: .kind)) ?? .plain
        hostOrigin = try c.decodeIfPresent(String.self, forKey: .hostOrigin) ?? ""
        headerName = try c.decodeIfPresent(String.self, forKey: .headerName) ?? ""
    }

    /// Reference names stay in a tiny alphabet so they parse unambiguously inside {{ }}.
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        return name.unicodeScalars.allSatisfy {
            ($0.value >= 0x30 && $0.value <= 0x39) ||   // 0-9
            ($0.value >= 0x41 && $0.value <= 0x5A) ||   // A-Z
            ($0.value >= 0x61 && $0.value <= 0x7A) ||   // a-z
            $0 == "_" || $0 == "-"
        }
    }

    /// True when `name` + `hostOrigin` collide with another secret in the list.
    public static func hasDuplicate(of secret: CurlSecret, in all: [CurlSecret]) -> Bool {
        all.contains { $0.id != secret.id && $0.name == secret.name && $0.hostOrigin == secret.hostOrigin }
    }
}
