// CurlScenarioValidator.swift
// ChappieCore
//
// Everything that can be wrong with a scenario WITHOUT sending a request. Pure and synchronous:
// the caller supplies `lookup` (how to find another scenario of the same folder) so the same code
// serves save (new text + folder), run (preflight) and delete (who still calls me).
//
// Every problem is collected, so a failed save lists all of them at once.

import Foundation

public struct CurlScenarioValidation: Equatable, Sendable {
    public var errors: [String]
    /// Longest call chain below (and including) this scenario; 1 = no calls.
    public var depth: Int
    /// True when the scenario writes data itself or through a callee. login steps do not count.
    public var writesData: Bool

    public var isValid: Bool { errors.isEmpty }
}

public enum CurlScenarioValidator {

    public typealias Lookup = (String) -> CurlScenario?

    public static func validate(_ scenario: CurlScenario, lookup: Lookup) -> CurlScenarioValidation {
        var errors: [String] = []
        validateShape(scenario, &errors)
        validateSteps(scenario, &errors)
        validateReferences(scenario, &errors)
        validateReturns(scenario, &errors)

        var visiting: [String] = [scenario.name]
        var cache: [String: Int] = [:]
        let depth = validateCalls(scenario, lookup: lookup, visiting: &visiting, depthCache: &cache, errors: &errors)
        if depth > CurlScenarioRules.maxDepth {
            errors.append("Call chain is \(depth) scenarios deep; the limit is \(CurlScenarioRules.maxDepth).")
        }

        let writes = writesData(scenario, lookup: lookup, visiting: [scenario.name])
        if writes && !scenario.mutates {
            errors.append("The scenario writes data (a non-GET step or a call to a scenario that does) but 'mutates' is false. Set \"mutates\": true so a run announces it.")
        }
        return CurlScenarioValidation(errors: dedupe(errors), depth: depth, writesData: writes)
    }

    // MARK: - Names, slots, inputs

    private static func validateShape(_ s: CurlScenario, _ errors: inout [String]) {
        if !CurlScenarioRules.isValidIdentifier(s.name) {
            errors.append("name '\(s.name)' must be letters, digits, '_' or '-' (max 64), because it is also the file name.")
        }
        if s.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("description must say in a sentence what the scenario does: it is what curl_scenario_info shows.")
        }
        for (label, names) in [("actors", s.actors), ("secrets", s.secrets), ("inputs", s.inputs.map(\.name))] {
            for name in names where !CurlScenarioRules.isValidIdentifier(name) {
                errors.append("\(label): '\(name)' must be letters, digits, '_' or '-' (no spaces or dots).")
            }
            for name in duplicates(names) { errors.append("\(label): '\(name)' is listed twice.") }
        }
        for name in Set(s.actors).intersection(s.secrets).sorted() {
            errors.append("'\(name)' is both an actor and a secret slot; pick one.")
        }
        if s.steps.count + s.cleanup.count > CurlScenarioRules.maxStepsPerScenario {
            errors.append("Too many steps (\(s.steps.count + s.cleanup.count)); the limit is \(CurlScenarioRules.maxStepsPerScenario). Split it into scenarios and use 'call'.")
        }
    }

    // MARK: - Steps

    private static let allowedHeaderBlocklist: Set<String> = ["cookie", "host", "content-length"]

    private static func validateSteps(_ s: CurlScenario, _ errors: inout [String]) {
        let ids = s.allSteps.map(\.id)
        for id in ids where !CurlScenarioRules.isValidIdentifier(id) {
            errors.append("step id '\(id)' must be letters, digits, '_' or '-'.")
        }
        for id in duplicates(ids) { errors.append("step id '\(id)' is used twice (cleanup steps count too).") }

        for step in s.allSteps {
            let label = "step '\(step.id)'"
            if let actor = step.actor, !s.actors.contains(actor) {
                errors.append("\(label): 'as' names '\(actor)', which is not in actors \(s.actors).")
            }
            switch step.action {
            case .request(let request):
                validateRequest(request, step: step, label: label, &errors)
            case .call(let call):
                if !CurlScenarioRules.isValidIdentifier(call.scenario) {
                    errors.append("\(label): call target '\(call.scenario)' is not a valid scenario name.")
                }
            }
        }
    }

    private static func validateRequest(_ r: CurlScenarioRequest, step: CurlScenarioStep, label: String, _ errors: inout [String]) {
        if !CurlScenarioDecoder.methods.contains(r.method) {
            errors.append("\(label): method '\(r.method)' is not one of \(CurlScenarioDecoder.methods.sorted().joined(separator: ", ")).")
        }
        if !r.path.hasPrefix("/") || r.path.contains("://") {
            errors.append("\(label): path '\(r.path)' must start with '/' and have no host; the host is chosen when the scenario runs.")
        }
        for header in r.headers where allowedHeaderBlocklist.contains(header.name.lowercased()) {
            errors.append("\(label): header '\(header.name)' cannot be set.")
        }
        if r.login != nil {
            if step.actor == nil { errors.append("\(label): a 'login' step needs 'as' (the actor that signs in).") }
            if CurlScenarioRules.readMethods.contains(r.method) {
                errors.append("\(label): a login step must be a POST (or other write) to the host's login path.")
            }
        }
    }

    // MARK: - Placeholders

    private static func validateReferences(_ s: CurlScenario, _ errors: inout [String]) {
        var known = Set<String>()       // variables visible to the next step
        let inputNames = Set(s.inputs.map(\.name))

        for step in s.steps { checkStep(step, s, inputNames, &known, &errors) }
        // Cleanup may use anything the main steps produced; a missing value is a runtime skip, not an error.
        var cleanupKnown = known
        for step in s.cleanup { checkStep(step, s, inputNames, &cleanupKnown, &errors) }
    }

    private static func checkStep(_ step: CurlScenarioStep, _ s: CurlScenario, _ inputs: Set<String>,
                                  _ known: inout Set<String>, _ errors: inout [String]) {
        let label = "step '\(step.id)'"
        var texts: [String] = []
        for check in step.expect.checks {
            switch check.operation {
            case .equals(let v), .contains(let v): texts.append(v)
            case .exists: break
            }
        }
        switch step.action {
        case .request(let r):
            texts += [r.path] + r.query.map(\.value) + r.headers.map(\.value)
            switch r.body {
            case .json(let t), .text(let t, _): texts.append(t)
            case .form(let pairs): texts += pairs.map(\.value)
            case nil: break
            }
            check(texts, label: label, scenario: s, inputs: inputs, known: known, extraVariables: [], &errors)
            if let login = r.login {
                let loginVariables = Set(login.extract.map(\.name))
                check(login.apply.map(\.template), label: "\(label) login.apply", scenario: s, inputs: inputs,
                      known: [], extraVariables: loginVariables, &errors)
            }
            for rule in r.extract {
                if known.contains(rule.name) { errors.append("\(label): variable '\(rule.name)' is already set by an earlier step.") }
                known.insert(rule.name)
            }
        case .call(let call):
            texts += call.with.map(\.value)
            check(texts, label: label, scenario: s, inputs: inputs, known: known, extraVariables: [], &errors)
            for name in call.returns { known.insert("\(step.id).\(name)") }
        }
    }

    private static func check(_ texts: [String], label: String, scenario s: CurlScenario, inputs: Set<String>,
                              known: Set<String>, extraVariables: Set<String>, _ errors: inout [String]) {
        for text in texts {
            let scan = CurlScenarioReferences.scan(text)
            if scan.malformed > 0 {
                errors.append("\(label): '{{' without a valid {{secret:slot.field}}, {{input:name}} or {{var:name}} placeholder in \"\(snippet(text))\".")
            }
            for ref in scan.references {
                switch ref.kind {
                case .secret:
                    guard s.secretSlots.contains(ref.name) else {
                        errors.append("\(label): {{secret:\(ref.name)…}} names no declared actor or secret. Declared: \(s.secretSlots.sorted()).")
                        continue
                    }
                    guard let field = ref.field, CurlScenarioRules.secretFields.contains(field) else {
                        errors.append("\(label): secret reference '\(ref.name)' needs .login, .password or .value.")
                        continue
                    }
                    if s.actors.contains(ref.name) && field == "value" {
                        errors.append("\(label): actor '\(ref.name)' is a login+password pair; use .login or .password.")
                    }
                case .input:
                    if !inputs.contains(ref.name) { errors.append("\(label): {{input:\(ref.name)}} is not a declared input.") }
                case .variable:
                    if !known.contains(ref.name) && !extraVariables.contains(ref.name) {
                        errors.append("\(label): {{var:\(ref.name)}} is not set by an earlier step (extract it first, or use {{var:stepId.returnedName}} after a call).")
                    }
                }
            }
        }
    }

    // MARK: - returns

    private static func validateReturns(_ s: CurlScenario, _ errors: inout [String]) {
        var produced = Set<String>()
        for step in s.steps {
            switch step.action {
            case .request(let r): produced.formUnion(r.extract.map(\.name))
            case .call(let c): produced.formUnion(c.returns.map { "\(step.id).\($0)" })
            }
        }
        for name in s.returns where !produced.contains(name) {
            errors.append("returns: '\(name)' is not produced by any step (an extract name, or stepId.name after a call).")
        }
    }

    // MARK: - Calls: existence, contract, cycles, depth

    @discardableResult
    private static func validateCalls(_ s: CurlScenario, lookup: Lookup, visiting: inout [String],
                                      depthCache: inout [String: Int], errors: inout [String]) -> Int {
        var deepest = 0
        for step in s.allSteps {
            guard let call = step.call else { continue }
            let label = "step '\(step.id)'"
            if visiting.contains(call.scenario) {
                errors.append("\(label): calling '\(call.scenario)' makes a cycle (\((visiting + [call.scenario]).joined(separator: " -> "))).")
                continue
            }
            guard let callee = lookup(call.scenario) else {
                errors.append("\(label): scenario '\(call.scenario)' does not exist in this folder.")
                continue
            }
            checkContract(call, callee: callee, caller: s, label: label, step: step, &errors)

            if let cached = depthCache[call.scenario] { deepest = max(deepest, cached); continue }
            visiting.append(call.scenario)
            // Errors inside a callee belong to the callee; only its depth and cycles matter here.
            var calleeErrors: [String] = []
            let depth = validateCalls(callee, lookup: lookup, visiting: &visiting, depthCache: &depthCache, errors: &calleeErrors)
            visiting.removeLast()
            errors.append(contentsOf: calleeErrors.filter { $0.contains("makes a cycle") }.map { "via '\(call.scenario)': \($0)" })
            depthCache[call.scenario] = depth
            deepest = max(deepest, depth)
        }
        return deepest + 1
    }

    private static func checkContract(_ call: CurlScenarioCall, callee: CurlScenario, caller: CurlScenario,
                                      label: String, step: CurlScenarioStep, _ errors: inout [String]) {
        let inputNames = Set(callee.inputs.map(\.name))
        let given = Set(call.with.map(\.name))
        for name in given.subtracting(inputNames).sorted() {
            errors.append("\(label): '\(call.scenario)' has no input '\(name)'. Its inputs: \(callee.inputs.map(\.name)).")
        }
        for input in callee.inputs where input.isRequired && !given.contains(input.name) {
            errors.append("\(label): required input '\(input.name)' of '\(call.scenario)' is missing in 'with'.")
        }
        for name in call.returns where !callee.returns.contains(name) {
            errors.append("\(label): '\(call.scenario)' does not return '\(name)'. It returns: \(callee.returns).")
        }
        for slot in callee.secrets where !caller.secrets.contains(slot) {
            errors.append("\(label): '\(call.scenario)' uses secret slot '\(slot)'; declare '\(slot)' in this scenario's secrets too (slots of the same name are passed through).")
        }
        // Actors: a single callee actor takes `as: "name"`; several need an object mapping every one.
        if callee.actors.count == 1, let only = callee.actors.first {
            if let name = step.actor { requireActor(name, in: caller, label, &errors) }
            else if let mapped = call.actorMap[only] { requireActor(mapped, in: caller, label, &errors) }
            else { errors.append("\(label): '\(call.scenario)' acts as '\(only)'; add \"as\": \"<actor of this scenario>\".") }
        } else if callee.actors.count > 1 {
            for actor in callee.actors {
                if let mapped = call.actorMap[actor] { requireActor(mapped, in: caller, label, &errors) }
                else { errors.append("\(label): map callee actor '\(actor)' with \"as\": {\"\(actor)\": \"<your actor>\", ...}.") }
            }
            if step.actor != nil { errors.append("\(label): '\(call.scenario)' has several actors, so 'as' must be an object.") }
        }
        for key in call.actorMap.keys where !callee.actors.contains(key) {
            errors.append("\(label): '\(call.scenario)' has no actor '\(key)'.")
        }
    }

    private static func requireActor(_ name: String, in caller: CurlScenario, _ label: String, _ errors: inout [String]) {
        if !caller.actors.contains(name) { errors.append("\(label): 'as' names '\(name)', which is not in this scenario's actors \(caller.actors).") }
    }

    // MARK: - mutates

    private static func writesData(_ s: CurlScenario, lookup: Lookup, visiting: [String]) -> Bool {
        for step in s.allSteps {
            switch step.action {
            case .request(let r):
                if r.login == nil && !CurlScenarioRules.readMethods.contains(r.method) { return true }
            case .call(let c):
                guard !visiting.contains(c.scenario), let callee = lookup(c.scenario) else { continue }
                if callee.mutates || writesData(callee, lookup: lookup, visiting: visiting + [c.scenario]) { return true }
            }
        }
        return false
    }

    // MARK: - Helpers

    private static func duplicates(_ names: [String]) -> [String] {
        var seen = Set<String>(), dupes = Set<String>()
        for name in names where !seen.insert(name).inserted { dupes.insert(name) }
        return dupes.sorted()
    }

    private static func dedupe(_ messages: [String]) -> [String] {
        var seen = Set<String>()
        return messages.filter { seen.insert($0).inserted }
    }

    private static func snippet(_ text: String) -> String {
        text.count <= 60 ? text : String(text.prefix(57)) + "..."
    }
}
