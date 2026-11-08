// CurlScenarioChecks.swift
// ChappieCore
//
// Evaluates a step's `expect` against the RAW answer. Pure: placeholders in the expected values are
// already substituted by the caller.
//
// Status: an empty list means "any 2xx", so a step that silently gets a 500 can never pass by accident.
// Paths use the `pick` syntax (`data.items[*].id`, `remark.comment`).
//   equals   : the value found has exactly this text (numbers and booleans as written).
//   contains : an array holds an element with exactly this text; a string contains it as a substring.
//   exists   : the path resolves to something that is not null.

import Foundation

enum CurlScenarioChecks {

    static let shownValueLimit = 120

    /// One message per failed expectation; empty = all passed.
    static func failures(statuses: [Int], checks: [CurlScenarioCheck], status: Int, body: Data) -> [String] {
        var problems: [String] = []
        if statuses.isEmpty {
            if !(200..<300).contains(status) { problems.append("expected a 2xx status, got \(status)") }
        } else if !statuses.contains(status) {
            let wanted = statuses.map(String.init).joined(separator: " or ")
            problems.append("expected status \(wanted), got \(status)")
        }
        for check in checks {
            if let message = evaluate(check, body: body) { problems.append(message) }
        }
        return problems
    }

    private static func evaluate(_ check: CurlScenarioCheck, body: Data) -> String? {
        let found = CurlJSONPath.resolve(check.path, in: body)
        let present = found != nil && !(found is NSNull)

        switch check.operation {
        case .exists(let wanted):
            if wanted == present { return nil }
            return wanted ? "'\(check.path)' is missing or null" : "'\(check.path)' exists but should not"

        case .equals(let expected):
            guard present, let found, let text = CurlJSONPath.text(of: found) else {
                return "'\(check.path)' was not found (expected '\(clip(expected))')"
            }
            return text == expected ? nil : "'\(check.path)' is '\(clip(text))', expected '\(clip(expected))'"

        case .contains(let expected):
            guard present, let found else { return "'\(check.path)' was not found (looking for '\(clip(expected))')" }
            if let array = found as? [Any] {
                let hit = array.contains { CurlJSONPath.text(of: $0) == expected }
                return hit ? nil : "'\(check.path)' has \(array.count) element(s), none equals '\(clip(expected))'"
            }
            guard let text = CurlJSONPath.text(of: found) else { return "'\(check.path)' has no text value" }
            return text.contains(expected) ? nil : "'\(check.path)' is '\(clip(text))', which does not contain '\(clip(expected))'"
        }
    }

    private static func clip(_ text: String) -> String {
        text.count <= shownValueLimit ? text : String(text.prefix(shownValueLimit - 1)) + "…"
    }
}
