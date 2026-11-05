// CurlToolArguments.swift
// ChappieCore
//
// Turns the flat string arguments of curl_* tool calls into engine value types. Objects and
// arrays reach us as compact JSON text (see ToolArguments), so every structured argument is
// parsed here, and a malformed one becomes a message the model can fix.

import Foundation

enum CurlToolArguments {

    struct Failure: Error { let message: String }

    // MARK: - JSON helpers

    /// A JSON object argument ("headers", "query", "form"); absent or blank = empty.
    static func object(_ args: [String: String], _ key: String) throws -> [String: Any] {
        guard let raw = args[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return [:] }
        guard let value = try? JSONSerialization.jsonObject(with: Data(raw.utf8)),
              let dict = value as? [String: Any] else {
            throw Failure(message: "Argument '\(key)' must be a JSON object, e.g. {\"name\": \"value\"}.")
        }
        return dict
    }

    /// A JSON array argument ("extract", "apply"); absent or blank = empty.
    static func array(_ args: [String: String], _ key: String) throws -> [[String: Any]] {
        guard let raw = args[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return [] }
        guard let value = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) else {
            throw Failure(message: "Argument '\(key)' must be a JSON array of objects.")
        }
        if let single = value as? [String: Any] { return [single] }
        guard let list = value as? [[String: Any]] else {
            throw Failure(message: "Argument '\(key)' must be a JSON array of objects.")
        }
        return list
    }

    /// Scalars become strings, nested values compact JSON text; keys sorted for a stable order.
    static func pairs(from dict: [String: Any]) -> [CurlPair] {
        dict.keys.sorted().map { CurlPair($0, text(of: dict[$0] as Any)) }
    }

    static func headers(_ args: [String: String]) throws -> [CurlHeader] {
        let dict = try object(args, "headers")
        return dict.keys.sorted().map { CurlHeader($0, text(of: dict[$0] as Any)) }
    }

    static func text(of value: Any) -> String {
        switch value {
        case let string as String: return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        case is NSNull: return ""
        default:
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    // MARK: - Request parts

    /// Exactly one of json / form / text may be given.
    static func body(_ args: [String: String]) throws -> CurlBody? {
        let json = args["json"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let form = args["form"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = args["text"] ?? ""
        let given = [!json.isEmpty, !form.isEmpty, !text.isEmpty].filter { $0 }.count
        if given > 1 { throw Failure(message: "Give only one body: 'json', 'form' or 'text'.") }
        if !json.isEmpty {
            // A template such as {"pw":"{{secret:x.password}}"} is valid JSON as it stands.
            guard (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])) != nil else {
                throw Failure(message: "Argument 'json' is not valid JSON.")
            }
            return .json(json)
        }
        if !form.isEmpty { return .form(pairs(from: try object(args, "form"))) }
        if !text.isEmpty { return .text(text, contentType: args["content_type"] ?? "") }
        return nil
    }

    // MARK: - Extraction rules

    /// "json:data.token", "header:X-Auth", "cookie:sid".
    static func source(_ spec: String) throws -> CurlExtractSource {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Failure(message: "Extraction source '\(spec)' must look like json:path, header:Name or cookie:name.")
        }
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        switch parts[0].lowercased() {
        case "json":   return .json(value)
        case "header": return .header(value)
        case "cookie": return .cookie(value)
        default: throw Failure(message: "Unknown extraction source '\(parts[0])'. Use json, header or cookie.")
        }
    }

    static func extractRules(_ items: [[String: Any]]) throws -> [CurlExtractRule] {
        try items.map { item in
            guard let name = item["name"] as? String, !name.isEmpty,
                  let from = item["from"] as? String else {
                throw Failure(message: "Each extraction rule needs 'name' and 'from', e.g. {\"name\":\"access_token\",\"from\":\"json:access_token\"}.")
            }
            let sensitive = (item["sensitive"] as? Bool) ?? ((item["sensitive"] as? String).map { $0.lowercased() != "false" } ?? true)
            return CurlExtractRule(name: name, source: try source(from), sensitive: sensitive)
        }
    }

    static func applyRules(_ items: [[String: Any]]) throws -> [CurlApplyRule] {
        try items.map { item in
            guard let header = item["header"] as? String, !header.isEmpty,
                  let template = item["template"] as? String else {
                throw Failure(message: "Each apply rule needs 'header' and 'template', e.g. {\"header\":\"Authorization\",\"template\":\"{{var:token_type}} {{var:access_token}}\"}.")
            }
            return CurlApplyRule(header: header, template: template)
        }
    }

    /// "pick": a JSON array of paths, or one bare path such as data.items[*].id.
    static func pick(_ args: [String: String]) throws -> [String] {
        guard let raw = args["pick"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return [] }
        guard raw.hasPrefix("[") else { return [raw] }
        guard let value = try? JSONSerialization.jsonObject(with: Data(raw.utf8)),
              let list = value as? [String] else {
            throw Failure(message: "Argument 'pick' must be a JSON array of path strings, e.g. [\"data.items[*].id\", \"paginate.total\"].")
        }
        return list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func flag(_ args: [String: String], _ key: String) -> Bool {
        ["true", "1", "yes"].contains((args[key] ?? "").lowercased())
    }
}
