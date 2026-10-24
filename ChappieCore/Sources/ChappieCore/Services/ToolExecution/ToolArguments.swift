// ToolArguments.swift
// ChappieCore
//
// Lenient reader for the JSON arguments a model sends with a tool call.
//
// WHY: every executor reads arguments as a flat [String: String] map. Strict decoding rejected the
// WHOLE object when a model wrote {"timeout": 30} or {"recursive": true}, and the callers turned that
// failure into an empty map — so even "project" was silently lost. Models differ in how strictly
// they follow a string-only schema, so we normalise instead of failing.
//
// RULES:
//   string          → as is
//   number / bool   → "30", "0.5", "true" / "false"
//   null            → key is dropped (same as not sending it)
//   array / object  → compact JSON text with sorted keys (tools such as memorize and
//                     loc_submit_batch expect JSON text inside a string argument)
//   "" / "null"     → no arguments at all
//   a JSON string that itself holds an object (double-encoded) → unwrapped once
// Anything that is not an object after that (array, bare number, broken JSON) is an explicit error
// the model can read and fix; it is never turned into "no arguments".

import Foundation

enum ToolArguments {

    enum ParseError: Error, Equatable {
        case invalidJSON
        case notAnObject
    }

    static func parse(_ raw: String) -> Result<[String: String], ParseError> {
        parse(data: Data(raw.utf8))
    }

    static func parse(data: Data) -> Result<[String: String], ParseError> {
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .success([:]) }

        var value: Any
        do {
            value = try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])
        } catch {
            return .failure(.invalidJSON)
        }

        // Some models JSON-encode the arguments twice: "{\"path\":\"a\"}".
        if let inner = value as? String {
            let innerTrimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            if innerTrimmed.isEmpty { return .success([:]) }
            guard let unwrapped = try? JSONSerialization.jsonObject(
                with: Data(innerTrimmed.utf8), options: [.fragmentsAllowed]
            ) else { return .failure(.notAnObject) }
            value = unwrapped
        }

        if value is NSNull { return .success([:]) }
        guard let object = value as? [String: Any] else { return .failure(.notAnObject) }

        var result: [String: String] = [:]
        for (key, item) in object {
            if let text = flatten(item) { result[key] = text }
        }
        return .success(result)
    }

    /// Message for the model when the arguments cannot be read at all.
    static func explanation(for error: ParseError, tool: String) -> String {
        switch error {
        case .invalidJSON:
            return "❌ Tool '\(tool)': the arguments are not valid JSON. Send a single JSON object, e.g. {\"path\": \"a.txt\"}."
        case .notAnObject:
            return "❌ Tool '\(tool)': the arguments must be a JSON object ({\"name\": value, …}), not an array or a bare value."
        }
    }

    // MARK: - Private

    private static func flatten(_ item: Any) -> String? {
        switch item {
        case is NSNull:
            return nil
        case let text as String:
            return text
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        case is [Any], is [String: Any]:
            guard JSONSerialization.isValidJSONObject(item),
                  let data = try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]) else { return nil }
            return String(decoding: data, as: UTF8.self)
        default:
            return nil
        }
    }
}
