// CurlContext.swift
// ChappieCore
//
// What the engine needs to know for one call: the thread's host allow-list, the projects'
// secret metadata and a way to read secret VALUES. The engine itself holds no configuration,
// so it can be shared app-wide across threads and projects.

import Foundation

public protocol CurlSecretValueProvider: Sendable {
    func value(secretId: UUID, field: CurlSecretField) -> String?
}

extension CurlSecretKeychain: CurlSecretValueProvider {
    public func value(secretId: UUID, field: CurlSecretField) -> String? {
        load(secretId: secretId, field: field)
    }
}

public struct CurlContext: Sendable {
    public var hosts: [CurlHost]
    public var secrets: [CurlSecret]
    public var values: any CurlSecretValueProvider

    public init(hosts: [CurlHost], secrets: [CurlSecret], values: any CurlSecretValueProvider) {
        self.hosts = hosts
        self.secrets = secrets
        self.values = values
    }

    /// Secrets bound to exactly this origin.
    func secrets(for origin: String) -> [CurlSecret] {
        secrets.filter { $0.hostOrigin == origin }
    }

    func secret(named name: String, origin: String) -> CurlSecret? {
        secrets.first { $0.name == name && $0.hostOrigin == origin }
    }

    /// Value of one reference, honouring the host binding. nil when the secret does not exist
    /// for this origin, the field does not belong to its kind, or no value is stored.
    func secretValue(_ ref: CurlReference, origin: String) -> String? {
        guard let secret = secret(named: ref.name, origin: origin) else { return nil }
        let fields = secret.kind.fields
        let field: CurlSecretField
        if let raw = ref.field {
            guard let parsed = CurlSecretField(rawValue: raw), fields.contains(parsed) else { return nil }
            field = parsed
        } else if fields.count == 1 {
            field = fields[0]
        } else {
            return nil
        }
        return values.value(secretId: secret.id, field: field)
    }

    /// All stored values of secrets bound to `origin`, for response redaction.
    func redactionEntries(origin: String) -> [(label: String, value: String)] {
        var entries: [(label: String, value: String)] = []
        for secret in secrets(for: origin) {
            for field in secret.kind.fields {
                if let value = values.value(secretId: secret.id, field: field) {
                    entries.append(("secret:\(secret.name).\(field.rawValue)", value))
                }
            }
        }
        return entries
    }
}
