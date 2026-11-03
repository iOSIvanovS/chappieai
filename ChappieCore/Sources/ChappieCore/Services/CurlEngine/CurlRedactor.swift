// CurlRedactor.swift
// ChappieCore
//
// Everything the engine returns to the model passes through here. Three layers:
//   1. Known values (secret values, sensitive session variables, cookie values) are removed
//      wherever they appear, including JSON-escaped and percent-encoded forms.
//   2. In JSON bodies, string values under keys that look like credentials are masked even if
//      we never saw them before (refresh_token, a second token the recipe did not extract...).
//      "token_type" is kept: it carries no secret and the model needs it.
//   3. Credential headers are masked by name.
//
// Values shorter than `minLength` are not matched textually: replacing a 2-character string
// everywhere would destroy the response without protecting anything.

import Foundation

public struct CurlRedactor: Sendable {

    public static let minLength = 4

    private struct Needle: Sendable {
        let text: String
        let label: String
    }

    private let needles: [Needle]
    private let redactJSONKeys: Bool

    /// - Parameter entries: (label, value) pairs; the label appears in the placeholder.
    public init(entries: [(label: String, value: String)], redactJSONKeys: Bool = true) {
        var seen = Set<String>()
        var built: [Needle] = []
        for entry in entries where entry.value.count >= Self.minLength {
            let variants = [
                entry.value,
                CurlEncoding.jsonEscaped(entry.value),
                CurlEncoding.percent(entry.value)
            ]
            for variant in variants where !variant.isEmpty && seen.insert(variant).inserted {
                built.append(Needle(text: variant, label: entry.label))
            }
        }
        // Longest first, so a value that contains a shorter one is replaced as a whole.
        self.needles = built.sorted { $0.text.count > $1.text.count }
        self.redactJSONKeys = redactJSONKeys
    }

    public func redact(_ text: String) -> String {
        guard !needles.isEmpty, !text.isEmpty else { return text }
        // Two-phase swap through unique markers, so replacement text can never be matched
        // by a later needle (a label may contain a fragment of some value).
        var work = text
        for (index, needle) in needles.enumerated() where work.contains(needle.text) {
            work = work.replacingOccurrences(of: needle.text, with: "\u{0}\(index)\u{0}")
        }
        for (index, needle) in needles.enumerated() {
            work = work.replacingOccurrences(of: "\u{0}\(index)\u{0}", with: "<redacted:\(needle.label)>")
        }
        return work
    }

    /// Response body: known values plus credential-looking JSON keys.
    public func redactBody(_ text: String) -> String {
        let known = redact(text)
        guard redactJSONKeys else { return known }
        let trimmed = known.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return known }
        return Self.maskSensitiveJSONKeys(known)
    }

    // MARK: - JSON keys

    private static let sensitiveWords = [
        "token", "password", "passwd", "secret", "authorization", "apikey", "cookie", "credential"
    ]

    static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        if normalized.contains("tokentype") { return false }
        return sensitiveWords.contains { normalized.contains($0) }
    }

    static func maskSensitiveJSONKeys(_ text: String) -> String {
        let pattern = #""((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let result = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let key = ns.substring(with: match.range(at: 1))
            let valueRange = match.range(at: 2)
            guard valueRange.length > 0, isSensitiveKey(key) else { continue }
            result.replaceCharacters(in: valueRange, with: "<redacted>")
        }
        return result as String
    }

    // MARK: - Headers

    private static let hiddenHeaders: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie", "x-csrf-token", "x-xsrf-token"
    ]

    /// Credential headers are masked by name; the rest go through known-value redaction.
    public func redactHeaders(_ headers: [CurlHeader]) -> [CurlHeader] {
        headers.compactMap { header in
            let lower = header.name.lowercased()
            if lower == "set-cookie" { return nil }   // rendered separately as cookie names
            let hidden = Self.hiddenHeaders.contains(lower)
                || lower.contains("token") || lower.contains("secret")
                || lower.contains("api-key") || lower.contains("apikey")
            return CurlHeader(header.name, hidden ? "<redacted>" : redact(header.value))
        }
    }
}
