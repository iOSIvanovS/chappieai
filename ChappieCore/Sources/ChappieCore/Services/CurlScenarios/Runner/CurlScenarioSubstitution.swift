// CurlScenarioSubstitution.swift
// ChappieCore
//
// The runner's half of placeholder substitution. The engine only knows {{secret:name.field}} and the
// SESSION's {{var:...}}; a scenario also has {{input:..}} and its own {{var:..}}, so the runner resolves
// those itself and rewrites secret SLOTS into real secret names. The engine then substitutes the secret
// values at send time, so a value never passes through the runner.
//
// INJECTION GUARD: the engine substitutes in a single pass, but it would still expand a "{{secret:..}}"
// that the runner pasted in as part of a variable value (for example one a hostile server returned). Such
// values are refused outright, including braces at their edges that could join with the template into "{{".

import Foundation

enum CurlScenarioSubstitution {

    /// Escaping for the place the text lands in (the engine escapes its own substitutions the same way).
    enum Mode { case raw, url, json }

    struct Outcome {
        var text: String
        /// Inputs or variables that have no value (a cleanup step is skipped for these).
        var missing: [String] = []
        /// Anything else that makes the text unusable.
        var problems: [String] = []
        var isClean: Bool { missing.isEmpty && problems.isEmpty }
    }

    static func apply(_ text: String, mode: Mode, scope: CurlScenarioScope, allowSecrets: Bool = true) -> Outcome {
        var outcome = Outcome(text: text)
        var missing: [String] = []
        var problems: [String] = []
        let slots = scope.slots

        let result = CurlScenarioReferences.replace(text) { reference, insideString in
            // In a JSON body a placeholder outside quotes ({"id": {{var:x}}}) must become a bare number,
            // true/false or null; that is how a request gets an integer where the server insists on one.
            let bare = mode == .json && !insideString
            switch reference.kind {
            case .secret:
                guard allowSecrets else {
                    problems.append("{{secret:\(reference.name)…}} is not allowed here (expectations and call inputs never take secrets)")
                    return nil
                }
                guard let field = reference.field, let real = slots[reference.name] else {
                    problems.append("secret slot '\(reference.name)' is not mapped to a secret")
                    return nil
                }
                return "{{secret:\(real).\(field)}}"
            case .input:
                guard let value = scope.inputs[reference.name] else {
                    missing.append("input:\(reference.name)")
                    return nil
                }
                if bare { return bareLiteral(value, reference: "input:\(reference.name)", problems: &problems) }
                return escaped(value, reference: "input:\(reference.name)", mode: mode, problems: &problems)
            case .variable:
                guard let value = scope.vars[reference.name]?.text else {
                    missing.append("var:\(reference.name)")
                    return nil
                }
                if bare { return bareLiteral(value, reference: "var:\(reference.name)", problems: &problems) }
                return escaped(value, reference: "var:\(reference.name)", mode: mode, problems: &problems)
            }
        }
        // The walk goes from the end of the text; report in reading order.
        outcome.text = result
        outcome.missing = missing.reversed()
        outcome.problems = problems.reversed()
        return outcome
    }

    static func isSafe(_ value: String) -> Bool {
        !value.contains("{{") && !value.hasPrefix("{") && !value.hasSuffix("{")
    }

    /// Only a JSON number, true, false or null may stand unquoted; anything else would break the body.
    private static func bareLiteral(_ value: String, reference: String, problems: inout [String]) -> String? {
        guard isSafe(value) else {
            problems.append("the value of {{\(reference)}} contains '{{' or starts/ends with '{'; refusing to build a request from it")
            return nil
        }
        let isLiteral = value == "true" || value == "false" || value == "null"
            || (!value.isEmpty && (try? JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed])) is NSNumber)
        guard isLiteral else {
            problems.append("{{\(reference)}} stands outside quotes in a JSON body, so its value must be a number, true, false or null, got '\(value.prefix(40))'")
            return nil
        }
        return value
    }

    private static func escaped(_ value: String, reference: String, mode: Mode, problems: inout [String]) -> String? {
        guard isSafe(value) else {
            problems.append("the value of {{\(reference)}} contains '{{' or starts/ends with '{'; refusing to build a request from it")
            return nil
        }
        switch mode {
        case .raw:  return value
        case .url:  return CurlEncoding.percent(value)
        case .json: return CurlEncoding.jsonEscaped(value)
        }
    }
}
