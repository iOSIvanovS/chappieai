// CurlValidation.swift
// ChappieCore
//
// Pure validation of Curl-Chappie settings rows. Lives in the core (not in the views) so the
// rules are unit-tested and the settings sheets only map an issue to a localized message.

import Foundation

// MARK: - Issues

public enum CurlHostIssue: Sendable, Equatable {
    case emptyName
    case invalidOrigin
    case duplicateOrigin
    /// `.readAndLogin` without a login path would behave exactly like `.readOnly` — almost certainly a mistake.
    case missingLoginPath
}

public enum CurlSecretIssue: Sendable, Equatable {
    case invalidName
    case duplicate
    case missingHost
    case missingHeaderName
}

// MARK: - Save gate

extension ThreadSettings {
    /// False when Curl-Chappie is on and a filled-in host row is invalid. Blank rows are ignored
    /// (dropped on save), and a disabled tool never blocks saving unrelated thread settings.
    public var curlHostsAreSaveable: Bool {
        guard curlEnabled else { return true }
        return !CurlValidation.hasIssues(CurlValidation.droppingBlank(curlHosts))
    }
}

extension ProjectSettings {
    /// False when a filled-in secret row is invalid. Blank rows are dropped on save.
    public var curlSecretsAreSaveable: Bool {
        !CurlValidation.hasIssues(CurlValidation.droppingBlank(curlSecrets))
    }
}

// MARK: - Validation

public enum CurlValidation {

    /// First problem found for a host row, or nil when the row is fine.
    public static func issue(for host: CurlHost, in all: [CurlHost]) -> CurlHostIssue? {
        if host.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyName }
        guard let origin = CurlOrigin.normalize(host.origin) else { return .invalidOrigin }
        let clash = all.contains { other in
            other.id != host.id && CurlOrigin.normalize(other.origin) == origin
        }
        if clash { return .duplicateOrigin }
        if host.permission == .readAndLogin, CurlOrigin.normalizePath(host.loginPath).isEmpty {
            return .missingLoginPath
        }
        return nil
    }

    /// First problem found for a secret row, or nil when the row is fine.
    public static func issue(for secret: CurlSecret, in all: [CurlSecret]) -> CurlSecretIssue? {
        if !CurlSecret.isValidName(secret.name) { return .invalidName }
        if CurlOrigin.normalize(secret.hostOrigin) == nil { return .missingHost }
        let normalized = CurlOrigin.normalize(secret.hostOrigin)
        let clash = all.contains { other in
            other.id != secret.id && other.name == secret.name
                && CurlOrigin.normalize(other.hostOrigin) == normalized
        }
        if clash { return .duplicate }
        if secret.kind == .customHeader,
           secret.headerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .missingHeaderName
        }
        return nil
    }

    public static func hasIssues(_ hosts: [CurlHost]) -> Bool {
        hosts.contains { issue(for: $0, in: hosts) != nil }
    }

    public static func hasIssues(_ secrets: [CurlSecret]) -> Bool {
        secrets.contains { issue(for: $0, in: secrets) != nil }
    }

    /// Rows the user added but never filled in. Dropped on save instead of blocking it.
    public static func droppingBlank(_ hosts: [CurlHost]) -> [CurlHost] {
        hosts.filter { !($0.name.trimmingCharacters(in: .whitespaces).isEmpty
                         && $0.origin.trimmingCharacters(in: .whitespaces).isEmpty) }
    }

    public static func droppingBlank(_ secrets: [CurlSecret]) -> [CurlSecret] {
        secrets.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
                         || !$0.hostOrigin.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Hosts with origin and login path normalized — applied on save so what is stored is
    /// exactly what request matching compares against.
    public static func normalized(_ hosts: [CurlHost]) -> [CurlHost] {
        hosts.map { host in
            var copy = host
            copy.name = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.origin = CurlOrigin.normalize(host.origin) ?? host.origin
            copy.loginPath = host.permission == .readAndLogin ? CurlOrigin.normalizePath(host.loginPath) : ""
            return copy
        }
    }

    /// Secrets with a normalized host and without a stale header name.
    public static func normalized(_ secrets: [CurlSecret]) -> [CurlSecret] {
        secrets.map { secret in
            var copy = secret
            copy.hostOrigin = CurlOrigin.normalize(secret.hostOrigin) ?? secret.hostOrigin
            copy.headerName = secret.kind == .customHeader
                ? secret.headerName.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return copy
        }
    }
}
