// CurlScenarioDecoder.swift
// ChappieCore
//
// JSON text -> CurlScenario. Strict on purpose: an unknown key is an error (a typo such as "expects"
// would otherwise silently drop a check), and every problem is collected so the model can fix the
// whole file in one round instead of one error at a time.

import Foundation

public struct CurlScenarioIssues: Error, Equatable, Sendable {
    public var messages: [String]
    public init(_ messages: [String]) { self.messages = messages }
}

enum CurlScenarioDecoder {

    static let topKeys: Set<String> = ["name", "description", "mutates", "actors", "secrets", "inputs", "steps", "returns", "cleanup"]
    static let stepKeys: Set<String> = [
        "id", "note", "as", "method", "path", "query", "headers", "json", "form", "text", "content_type",
        "login", "extract", "expect", "call", "with", "returns"
    ]
    static let methods: Set<String> = ["GET", "HEAD", "OPTIONS", "POST", "PUT", "PATCH", "DELETE"]

    static func decode(_ data: Data) -> Result<CurlScenario, CurlScenarioIssues> {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(CurlScenarioIssues(["The scenario must be one JSON object."]))
        }
        var errors: [String] = []
        for key in root.keys.sorted() where !topKeys.contains(key) {
            errors.append("Unknown key '\(key)'. Allowed: \(topKeys.sorted().joined(separator: ", ")).")
        }

        let name = string(root["name"], "name", &errors, required: true)
        let description = string(root["description"], "description", &errors, required: true)
        let mutates = bool(root["mutates"], "mutates", &errors) ?? false
        let actors = stringList(root["actors"], "actors", &errors)
        let secrets = stringList(root["secrets"], "secrets", &errors)
        let returns = stringList(root["returns"], "returns", &errors)
        let inputs = decodeInputs(root["inputs"], &errors)
        let steps = decodeSteps(root["steps"], "steps", &errors, required: true)
        let cleanup = decodeSteps(root["cleanup"], "cleanup", &errors, required: false)

        guard errors.isEmpty else { return .failure(CurlScenarioIssues(errors)) }
        return .success(CurlScenario(
            name: name, description: description, mutates: mutates, actors: actors, secrets: secrets,
            inputs: inputs, steps: steps, returns: returns, cleanup: cleanup))
    }

    // MARK: - Top level pieces

    private static func decodeInputs(_ value: Any?, _ errors: inout [String]) -> [CurlScenarioInput] {
        guard let value else { return [] }
        guard let list = value as? [[String: Any]] else {
            errors.append("'inputs' must be an array of objects: {\"name\", \"description\"?, \"default\"?}.")
            return []
        }
        var out: [CurlScenarioInput] = []
        for (index, item) in list.enumerated() {
            let label = "inputs[\(index)]"
            for key in item.keys.sorted() where !["name", "description", "default"].contains(key) {
                errors.append("\(label): unknown key '\(key)'.")
            }
            let name = string(item["name"], "\(label).name", &errors, required: true)
            let description = string(item["description"], "\(label).description", &errors, required: false)
            var defaultValue: String?
            if let raw = item["default"], !(raw is NSNull) {
                if raw is [Any] || raw is [String: Any] {
                    errors.append("\(label).default must be a string, number or boolean.")
                } else {
                    defaultValue = CurlToolArguments.text(of: raw)
                }
            }
            out.append(CurlScenarioInput(name: name, description: description, defaultValue: defaultValue))
        }
        return out
    }

    private static func decodeSteps(_ value: Any?, _ key: String, _ errors: inout [String], required: Bool) -> [CurlScenarioStep] {
        guard let value else {
            if required { errors.append("'\(key)' is required.") }
            return []
        }
        guard let list = value as? [[String: Any]] else {
            errors.append("'\(key)' must be an array of step objects.")
            return []
        }
        if required && list.isEmpty { errors.append("'\(key)' must not be empty.") }
        return list.enumerated().compactMap { index, item in
            decodeStep(item, label: "\(key)[\(index)]", &errors)
        }
    }

    // MARK: - Step

    private static func decodeStep(_ item: [String: Any], label rawLabel: String, _ errors: inout [String]) -> CurlScenarioStep? {
        let id = string(item["id"], "\(rawLabel).id", &errors, required: true)
        let label = id.isEmpty ? rawLabel : "\(rawLabel) '\(id)'"
        for key in item.keys.sorted() where !stepKeys.contains(key) {
            errors.append("\(label): unknown key '\(key)'.")
        }
        let note = string(item["note"], "\(label).note", &errors, required: false)
        let expect = decodeExpect(item["expect"], label, &errors)
        let isCall = item["call"] != nil

        if isCall {
            for key in ["method", "path", "query", "headers", "json", "form", "text", "content_type", "login", "extract"] where item[key] != nil {
                errors.append("\(label): a 'call' step cannot have '\(key)'.")
            }
            return decodeCall(item, id: id, note: note, expect: expect, label, &errors)
        }
        for key in ["with", "returns"] where item[key] != nil {
            errors.append("\(label): '\(key)' belongs to a 'call' step.")
        }
        let actor = item["as"] == nil ? nil : string(item["as"], "\(label).as", &errors, required: false)
        guard let request = decodeRequest(item, label, &errors) else { return nil }
        return CurlScenarioStep(id: id, note: note, actor: actor, expect: expect, action: .request(request))
    }

    private static func decodeRequest(_ item: [String: Any], _ label: String, _ errors: inout [String]) -> CurlScenarioRequest? {
        let method = string(item["method"], "\(label).method", &errors, required: true).uppercased()
        let path = string(item["path"], "\(label).path", &errors, required: true)
        let query = pairs(item["query"], "\(label).query", &errors)
        let headers = pairs(item["headers"], "\(label).headers", &errors).map { CurlHeader($0.name, $0.value) }
        let body = decodeBody(item, label, &errors)
        let login = decodeLogin(item["login"], label, &errors)
        let extract = decodeExtract(item["extract"], "\(label).extract", &errors, sensitiveByDefault: false)
        return CurlScenarioRequest(method: method, path: path, query: query, headers: headers, body: body, login: login, extract: extract)
    }

    private static func decodeCall(_ item: [String: Any], id: String, note: String, expect: CurlScenarioExpect,
                                   _ label: String, _ errors: inout [String]) -> CurlScenarioStep? {
        let scenario = string(item["call"], "\(label).call", &errors, required: true)
        var actor: String?
        var actorMap: [String: String] = [:]
        if let raw = item["as"] {
            if let single = raw as? String { actor = single }
            else if let map = raw as? [String: Any] {
                for (callee, caller) in map {
                    guard let name = caller as? String else {
                        errors.append("\(label).as: values must be strings (the caller's actor).")
                        continue
                    }
                    actorMap[callee] = name
                }
            } else {
                errors.append("\(label).as must be an actor name or an object {calleeActor: callerActor}.")
            }
        }
        let with = pairs(item["with"], "\(label).with", &errors)
        let returns = stringList(item["returns"], "\(label).returns", &errors)
        return CurlScenarioStep(id: id, note: note, actor: actor, expect: expect,
                                action: .call(CurlScenarioCall(scenario: scenario, actorMap: actorMap, with: with, returns: returns)))
    }

    private static func decodeBody(_ item: [String: Any], _ label: String, _ errors: inout [String]) -> CurlBody? {
        let given = ["json", "form", "text"].filter { item[$0] != nil }
        if given.count > 1 { errors.append("\(label): give only one body (json, form or text).") }
        if let json = item["json"] {
            if let text = json as? String {
                // A placeholder may stand UNQUOTED here ({"id": {{var:x}}}) so the server gets a number, not a
                // string; for the syntax check every placeholder is swapped for a literal that fits both spots.
                let probe = CurlScenarioReferences.replace(text) { _ in "0" }
                guard (try? JSONSerialization.jsonObject(with: Data(probe.utf8), options: [.fragmentsAllowed])) != nil else {
                    errors.append("\(label).json is text but not valid JSON; write the body as a JSON object instead.")
                    return nil
                }
                return .json(text)
            }
            guard json is [String: Any] || json is [Any],
                  JSONSerialization.isValidJSONObject(json),
                  let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]) else {
                errors.append("\(label).json must be a JSON object or array.")
                return nil
            }
            return .json(String(decoding: data, as: UTF8.self))
        }
        if item["form"] != nil { return .form(pairs(item["form"], "\(label).form", &errors)) }
        if item["text"] != nil {
            return .text(string(item["text"], "\(label).text", &errors, required: false),
                         contentType: string(item["content_type"], "\(label).content_type", &errors, required: false))
        }
        return nil
    }

    private static func decodeLogin(_ value: Any?, _ label: String, _ errors: inout [String]) -> CurlScenarioLogin? {
        guard let value else { return nil }
        guard let object = value as? [String: Any] else {
            errors.append("\(label).login must be an object {extract, apply?}.")
            return nil
        }
        for key in object.keys.sorted() where !["extract", "apply"].contains(key) {
            errors.append("\(label).login: unknown key '\(key)'.")
        }
        let extract = decodeExtract(object["extract"], "\(label).login.extract", &errors, sensitiveByDefault: true)
        if extract.isEmpty { errors.append("\(label).login.extract must name at least one value to keep (for example the token).") }
        var apply: [CurlApplyRule] = []
        if let raw = object["apply"] {
            guard let list = raw as? [[String: Any]] else {
                errors.append("\(label).login.apply must be an array of {header, template}.")
                return CurlScenarioLogin(extract: extract)
            }
            for (index, rule) in list.enumerated() {
                guard let header = rule["header"] as? String, !header.isEmpty, let template = rule["template"] as? String else {
                    errors.append("\(label).login.apply[\(index)] needs 'header' and 'template'.")
                    continue
                }
                apply.append(CurlApplyRule(header: header, template: template))
            }
        }
        return CurlScenarioLogin(extract: extract, apply: apply)
    }

    /// {"name": "json:path"} or {"name": {"from": "json:path", "sensitive": false}}.
    private static func decodeExtract(_ value: Any?, _ label: String, _ errors: inout [String], sensitiveByDefault: Bool) -> [CurlExtractRule] {
        guard let value else { return [] }
        guard let object = value as? [String: Any] else {
            errors.append("\(label) must be an object {variableName: \"json:path\"}.")
            return []
        }
        var rules: [CurlExtractRule] = []
        for name in object.keys.sorted() {
            var spec: String?
            var sensitive = sensitiveByDefault ? true : CurlRedactor.isSensitiveKey(name)
            if let text = object[name] as? String { spec = text }
            else if let detail = object[name] as? [String: Any] {
                spec = detail["from"] as? String
                if let flag = detail["sensitive"] as? Bool { sensitive = flag }
            }
            guard let spec else {
                errors.append("\(label).\(name) must be \"json:path\" (or header:Name, cookie:name) or {\"from\", \"sensitive\"}.")
                continue
            }
            do { rules.append(CurlExtractRule(name: name, source: try CurlToolArguments.source(spec), sensitive: sensitive)) }
            catch let failure as CurlToolArguments.Failure { errors.append("\(label).\(name): \(failure.message)") }
            catch { errors.append("\(label).\(name): invalid source.") }
        }
        return rules
    }

    private static func decodeExpect(_ value: Any?, _ label: String, _ errors: inout [String]) -> CurlScenarioExpect {
        guard let value else { return CurlScenarioExpect() }
        guard let object = value as? [String: Any] else {
            errors.append("\(label).expect must be an object {status?, checks?}.")
            return CurlScenarioExpect()
        }
        for key in object.keys.sorted() where !["status", "checks"].contains(key) {
            errors.append("\(label).expect: unknown key '\(key)'.")
        }
        var statuses: [Int] = []
        if let raw = object["status"] {
            let list: [Any] = (raw as? [Any]) ?? [raw]
            for item in list {
                if let code = (item as? NSNumber)?.intValue, (100...599).contains(code) { statuses.append(code) }
                else { errors.append("\(label).expect.status must be an HTTP status (100-599) or an array of them.") }
            }
        }
        var checks: [CurlScenarioCheck] = []
        if let raw = object["checks"] {
            guard let list = raw as? [[String: Any]] else {
                errors.append("\(label).expect.checks must be an array of {path, equals|contains|exists}.")
                return CurlScenarioExpect(statuses: statuses)
            }
            for (index, item) in list.enumerated() {
                if let check = decodeCheck(item, "\(label).expect.checks[\(index)]", &errors) { checks.append(check) }
            }
        }
        return CurlScenarioExpect(statuses: statuses, checks: checks)
    }

    private static func decodeCheck(_ item: [String: Any], _ label: String, _ errors: inout [String]) -> CurlScenarioCheck? {
        for key in item.keys.sorted() where !["path", "equals", "contains", "exists"].contains(key) {
            errors.append("\(label): unknown key '\(key)'.")
        }
        let path = string(item["path"], "\(label).path", &errors, required: true)
        let operations = ["equals", "contains", "exists"].filter { item[$0] != nil }
        guard operations.count == 1 else {
            errors.append("\(label): give exactly one of equals, contains, exists.")
            return nil
        }
        switch operations[0] {
        case "equals":   return CurlScenarioCheck(path: path, operation: .equals(CurlToolArguments.text(of: item["equals"] as Any)))
        case "contains": return CurlScenarioCheck(path: path, operation: .contains(CurlToolArguments.text(of: item["contains"] as Any)))
        default:
            guard let flag = item["exists"] as? Bool else {
                errors.append("\(label).exists must be true or false.")
                return nil
            }
            return CurlScenarioCheck(path: path, operation: .exists(flag))
        }
    }

    // MARK: - Scalars

    private static func string(_ value: Any?, _ label: String, _ errors: inout [String], required: Bool) -> String {
        guard let value, !(value is NSNull) else {
            if required { errors.append("\(label) is required.") }
            return ""
        }
        guard let text = value as? String else {
            errors.append("\(label) must be a string.")
            return ""
        }
        if required && text.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("\(label) must not be empty.") }
        return text
    }

    private static func bool(_ value: Any?, _ label: String, _ errors: inout [String]) -> Bool? {
        guard let value else { return nil }
        guard let flag = value as? Bool else {
            errors.append("\(label) must be true or false.")
            return nil
        }
        return flag
    }

    private static func stringList(_ value: Any?, _ label: String, _ errors: inout [String]) -> [String] {
        guard let value else { return [] }
        guard let list = value as? [String] else {
            errors.append("\(label) must be an array of strings.")
            return []
        }
        return list
    }

    /// Object of scalars -> sorted pairs (nested values become compact JSON text).
    private static func pairs(_ value: Any?, _ label: String, _ errors: inout [String]) -> [CurlPair] {
        guard let value else { return [] }
        guard let object = value as? [String: Any] else {
            errors.append("\(label) must be an object.")
            return []
        }
        return CurlToolArguments.pairs(from: object)
    }
}
