// CurlSecretCatalog.swift
// ChappieCore
//
// Builds the part of the curl tool descriptions that tells the model WHICH secrets exist:
// name, kind, bound host and the reference syntax. Never a value — the model must know what to
// call a secret (`session: "sk"`), but must never see what it contains.

import Foundation

public enum CurlSecretCatalog {

    public struct Entry: Sendable {
        public let project: String
        public let secret: CurlSecret
        /// Parts that have no value in the Keychain yet (e.g. after migrating to a new Mac).
        public let missing: [CurlSecretField]

        public init(project: String, secret: CurlSecret, missing: [CurlSecretField]) {
            self.project = project
            self.secret = secret
            self.missing = missing
        }
    }

    /// One line per secret, grouped by project. Empty input gives an explicit "none" sentence so
    /// the model asks the user instead of guessing names.
    public static func describe(_ entries: [Entry]) -> String {
        guard !entries.isEmpty else {
            return "No secrets are configured (EXECUTOR projects have none yet): ask the user to add them in project settings."
        }
        let grouped = Dictionary(grouping: entries, by: \.project)
        let blocks = grouped.keys.sorted().map { project -> String in
            let lines = grouped[project]!
                .sorted { $0.secret.name < $1.secret.name }
                .map(line)
            return "Project '\(project)':\n" + lines.joined(separator: "\n")
        }
        return "Secrets (names only, values are hidden). Use the name as `session` and in references:\n" + blocks.joined(separator: "\n")
    }

    private static func line(_ entry: Entry) -> String {
        let secret = entry.secret
        let refs = secret.kind.fields.map { "{{secret:\(secret.name).\($0.rawValue)}}" }.joined(separator: ", ")
        var text = "- \"\(secret.name)\": \(kindLabel(secret)) for \(secret.hostOrigin); refs \(refs)"
        if !entry.missing.isEmpty {
            text += " — VALUE NOT ENTERED (\(entry.missing.map(\.rawValue).joined(separator: ", "))): ask the user to fill it in"
        }
        return text
    }

    private static func kindLabel(_ secret: CurlSecret) -> String {
        switch secret.kind {
        case .loginPassword: return "login+password"
        case .token:         return "token"
        case .customHeader:  return "header \(secret.headerName.isEmpty ? "(unnamed)" : secret.headerName)"
        case .plain:         return "plain string"
        }
    }
}
