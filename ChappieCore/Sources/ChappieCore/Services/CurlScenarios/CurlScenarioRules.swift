// CurlScenarioRules.swift
// ChappieCore
//
// Shared limits, the identifier rule and the placeholder scanner of Curl-Chappie scenarios.
//
// Three placeholder kinds live in a scenario file (the engine only knows the first two, so the runner
// resolves {{input:..}} and scenario-level {{var:..}} itself and maps secret SLOTS to real secrets):
//   {{secret:slot.field}}  slot = an actor or a declared secret; field = login | password | value
//   {{input:name}}         a run parameter
//   {{var:name}}           a value extracted by an earlier step, or {{var:stepId.returned}} from a call

import Foundation

public enum CurlScenarioRules {
    /// Scenarios in one call chain, the root included (root -> a -> b -> c -> d = 5).
    public static let maxDepth = 5
    public static let maxStepsPerScenario = 60
    /// A bigger file is refused when read: a scenario is a short script, not a data dump.
    public static let maxFileBytes = 256_000

    public static let readMethods: Set<String> = ["GET", "HEAD", "OPTIONS"]
    public static let secretFields: Set<String> = ["login", "password", "value"]

    /// Letters and digits of any script (a scenario may be called "Авторизация"), "_" and "-".
    /// No spaces and no dots: a dot separates `slot.field` and `stepId.returned`.
    public static func isValidIdentifier(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 64 else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            scalar == "_" || scalar == "-" ||
            scalar.properties.isAlphabetic ||
            scalar.properties.generalCategory == .decimalNumber ||
            scalar.properties.generalCategory == .nonspacingMark
        }
    }
}

// MARK: - Placeholder scanner

struct CurlScenarioReference: Equatable {
    enum Kind { case secret, variable, input }
    let kind: Kind
    /// secret: the slot; variable/input: the whole name (a variable may read `stepId.returned`).
    let name: String
    /// secret only.
    let field: String?
}

enum CurlScenarioReferences {

    struct Scan {
        var references: [CurlScenarioReference]
        /// Number of "{{" that did not form a valid placeholder.
        var malformed: Int
    }

    private static let regex: NSRegularExpression = {
        // The pattern is a constant, so construction cannot fail.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\{\{\s*(secret|var|input)\s*:\s*([^{}]*?)\s*\}\}"#)
    }()

    static func scan(_ text: String) -> Scan {
        guard text.contains("{{") else { return Scan(references: [], malformed: 0) }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var references: [CurlScenarioReference] = []
        for match in matches {
            let kindText = ns.substring(with: match.range(at: 1))
            let body = ns.substring(with: match.range(at: 2))
            switch kindText {
            case "secret":
                let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                references.append(CurlScenarioReference(kind: .secret, name: parts[0], field: parts.count > 1 ? parts[1] : nil))
            case "var":
                references.append(CurlScenarioReference(kind: .variable, name: body, field: nil))
            default:
                references.append(CurlScenarioReference(kind: .input, name: body, field: nil))
            }
        }
        let opened = text.components(separatedBy: "{{").count - 1
        return Scan(references: references, malformed: max(0, opened - matches.count))
    }

    /// Replaces every placeholder using `resolve` (nil = keep as written). Single pass: a substituted
    /// value is never scanned again.
    static func replace(_ text: String, _ resolve: (CurlScenarioReference) -> String?) -> String {
        guard text.contains("{{") else { return text }
        let ns = text as NSString
        let result = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let kindText = ns.substring(with: match.range(at: 1))
            let body = ns.substring(with: match.range(at: 2))
            let reference: CurlScenarioReference
            switch kindText {
            case "secret":
                let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                reference = CurlScenarioReference(kind: .secret, name: parts[0], field: parts.count > 1 ? parts[1] : nil)
            case "var":
                reference = CurlScenarioReference(kind: .variable, name: body, field: nil)
            default:
                reference = CurlScenarioReference(kind: .input, name: body, field: nil)
            }
            if let value = resolve(reference) { result.replaceCharacters(in: match.range, with: value) }
        }
        return result as String
    }
}
