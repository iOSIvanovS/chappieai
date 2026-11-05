// CurlTemplate.swift
// ChappieCore
//
// Placeholder substitution for Curl-Chappie requests.
//   {{secret:name.field}}  — Keychain value bound to the request origin
//   {{var:name}}           — value stored in the session by an extraction rule
//
// Substitution is a SINGLE pass: a substituted value that itself contains "{{...}}" is never
// expanded again, so a hostile server response cannot smuggle a secret reference into a request.

import Foundation

public struct CurlReference: Hashable, Sendable {
    public enum Kind: Sendable { case secret, variable }
    public let kind: Kind
    public let name: String
    public let field: String?

    public var description: String {
        let prefix = kind == .secret ? "secret" : "var"
        return field.map { "\(prefix):\(name).\($0)" } ?? "\(prefix):\(name)"
    }
}

/// How a substituted value is escaped for the place it lands in.
public enum CurlSubstitutionMode: Sendable {
    case raw
    /// Percent-encoded (URL path/query pieces).
    case urlComponent
    /// Escaped for the inside of a JSON string literal.
    case jsonString
}

public struct CurlSubstitution: Sendable, Equatable {
    public let text: String
    /// Descriptions of references that could not be resolved, e.g. "secret:sk_test.password".
    public let unresolved: [String]
}

public enum CurlTemplate {

    // The name is lazy and may hold inner spaces ("Юлин логин"); the optional ".field" is always Latin
    // (login / password / value). Keep the name class in step with CurlSecret.isValidName.
    private static let pattern = #"\{\{\s*(secret|var):([\p{L}\p{N}\p{M}_\- ]+?)(?:\.([A-Za-z0-9_\-]+))?\s*\}\}"#

    private static func regex() -> NSRegularExpression {
        // The pattern is a constant, so construction cannot fail.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    private static func reference(from match: NSTextCheckingResult, in text: NSString) -> CurlReference {
        let kind: CurlReference.Kind = text.substring(with: match.range(at: 1)) == "secret" ? .secret : .variable
        let name = text.substring(with: match.range(at: 2))
        let fieldRange = match.range(at: 3)
        let field = fieldRange.location == NSNotFound ? nil : text.substring(with: fieldRange)
        return CurlReference(kind: kind, name: name, field: field)
    }

    public static func references(in text: String) -> [CurlReference] {
        let ns = text as NSString
        return regex().matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { reference(from: $0, in: ns) }
    }

    /// Every placeholder becomes "_". Lets the caller parse the structure of a URL
    /// (origin, path shape) before any value is substituted.
    public static func neutralized(_ text: String) -> String {
        let ns = text as NSString
        return regex().stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "_")
    }

    public static func substitute(
        _ text: String,
        mode: CurlSubstitutionMode,
        resolver: (CurlReference) -> String?
    ) -> CurlSubstitution {
        let ns = text as NSString
        let matches = regex().matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return CurlSubstitution(text: text, unresolved: []) }

        let result = NSMutableString(string: text)
        var unresolved: [String] = []
        for match in matches.reversed() {
            let ref = reference(from: match, in: ns)
            guard let value = resolver(ref) else {
                unresolved.append(ref.description)
                continue
            }
            result.replaceCharacters(in: match.range, with: encode(value, mode))
        }
        return CurlSubstitution(text: result as String, unresolved: unresolved.reversed())
    }

    private static func encode(_ value: String, _ mode: CurlSubstitutionMode) -> String {
        switch mode {
        case .raw:          return value
        case .urlComponent: return CurlEncoding.percent(value)
        case .jsonString:   return CurlEncoding.jsonEscaped(value)
        }
    }
}

// MARK: - CurlEncoding

enum CurlEncoding {

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func percent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    /// Escapes for the inside of a JSON string (no surrounding quotes).
    static func jsonEscaped(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
