// CurlScenarioPreflight.swift
// ChappieCore
//
// Everything that can refuse a run BEFORE the first request: the arguments (inputs, slot mapping), the
// secrets (exist for this host, have their values) and the host gate for every step that will actually
// run (main steps of every called scenario, plus the ROOT cleanup; cleanup of called scenarios never
// runs, so it is not checked). A run that would be stopped halfway by a denied cleanup DELETE never starts.
//
// Pure and synchronous: it walks the scenario tree with the same slot bindings the executor uses.

import Foundation

struct CurlScenarioPreflight {

    struct Plan {
        var scope: CurlScenarioScope
        /// Upper bound of requests the run can send (every step counted once; a reused login sends none).
        var maxRequests: Int
        var writesData: Bool
        var scenarioCount: Int
    }

    private let store: CurlScenarioStore
    private let context: CurlContext
    private let origin: String
    private var issues: [String] = []
    private var maxRequests = 0
    private var scenarioCount = 0
    private var checkedSecrets = Set<String>()

    private init(store: CurlScenarioStore, context: CurlContext, origin: String) {
        self.store = store
        self.context = context
        self.origin = origin
    }

    static func check(
        request: CurlScenarioRunRequest, root: CurlScenario, store: CurlScenarioStore,
        context: CurlContext, origin: String
    ) -> Result<Plan, CurlScenarioIssues> {
        var pre = CurlScenarioPreflight(store: store, context: context, origin: origin)

        let scope = CurlScenarioScope(
            scenario: root,
            actors: pre.mapSlots(root.actors, given: request.actors, label: "actors"),
            secrets: pre.mapSlots(root.secrets, given: request.secrets, label: "secrets"),
            inputs: pre.resolveInputs(root, given: request.inputs))

        pre.walk(scope, isRoot: true)
        if pre.maxRequests > CurlEngine.requestsPerMinute {
            pre.issues.append("The run could send up to \(pre.maxRequests) requests, above the \(CurlEngine.requestsPerMinute)/minute limit; split the scenario.")
        }
        guard pre.issues.isEmpty else { return .failure(CurlScenarioIssues(dedupe(pre.issues))) }

        let writes = CurlScenarioValidator.validate(root) { store.load($0) }.writesData
        return .success(Plan(scope: scope, maxRequests: pre.maxRequests, writesData: writes, scenarioCount: pre.scenarioCount))
    }

    // MARK: - Arguments

    private mutating func mapSlots(_ slots: [String], given: [String: String], label: String) -> [String: String] {
        for key in given.keys.sorted() where !slots.contains(key) {
            issues.append("\(label): '\(key)' is not a slot of this scenario. Its \(label): \(slots.isEmpty ? "none" : slots.joined(separator: ", ")).")
        }
        var mapped: [String: String] = [:]
        for slot in slots { mapped[slot] = given[slot] ?? slot }
        return mapped
    }

    private mutating func resolveInputs(_ scenario: CurlScenario, given: [String: String]) -> [String: String] {
        let known = Set(scenario.inputs.map(\.name))
        for key in given.keys.sorted() where !known.contains(key) {
            issues.append("inputs: '\(key)' is not an input of '\(scenario.name)'. Its inputs: \(known.isEmpty ? "none" : known.sorted().joined(separator: ", ")).")
        }
        var values: [String: String] = [:]
        for input in scenario.inputs {
            if let value = given[input.name] ?? input.defaultValue { values[input.name] = value }
            else { issues.append("inputs: '\(input.name)' is required and was not given.") }
        }
        return values
    }

    // MARK: - Walk

    private mutating func walk(_ scope: CurlScenarioScope, isRoot: Bool) {
        scenarioCount += 1
        let scenario = scope.scenario
        for (slot, real) in scope.actors.sorted(by: { $0.key < $1.key }) {
            checkSecret(real, needsLogin: true, label: "actor '\(slot)' of '\(scenario.name)'")
        }
        for (slot, real) in scope.secrets.sorted(by: { $0.key < $1.key }) {
            checkSecret(real, needsLogin: false, label: "secret slot '\(slot)' of '\(scenario.name)'")
        }

        for step in isRoot ? scenario.steps + scenario.cleanup : scenario.steps {
            let label = "\(scenario.name)/\(step.id)"
            if let actor = step.actor, scope.actors[actor] == nil, step.request != nil {
                issues.append("step '\(label)': actor '\(actor)' is not mapped to a secret.")
            }
            switch step.action {
            case .request(let request):
                maxRequests += 1
                checkGate(request, label: label)
                checkReferences(step, scope: scope, label: label)
            case .call(let call):
                walkCall(call, step: step, scope: scope, label: label)
            }
        }
    }

    private mutating func walkCall(_ call: CurlScenarioCall, step: CurlScenarioStep, scope: CurlScenarioScope, label: String) {
        guard let callee = store.load(call.scenario) else {
            issues.append("step '\(label)': scenario '\(call.scenario)' does not exist.")
            return
        }
        switch CurlScenarioBindings.child(call: call, step: step, callee: callee,
                                          parentActors: scope.actors, parentSecrets: scope.secrets) {
        case .failure(let error):
            issues.append("step '\(label)': \(error.message)")
        case .success(let child):
            var inputs: [String: String] = [:]
            for input in callee.inputs { if let value = input.defaultValue { inputs[input.name] = value } }
            for pair in call.with { inputs[pair.name] = "" }    // value comes from a variable at run time
            walk(CurlScenarioScope(scenario: callee, actors: child.actors, secrets: child.secrets, inputs: inputs), isRoot: false)
        }
    }

    // MARK: - Checks

    private mutating func checkSecret(_ name: String, needsLogin: Bool, label: String) {
        guard checkedSecrets.insert("\(name)|\(needsLogin)").inserted else { return }
        guard let secret = context.secret(named: name, origin: origin) else {
            issues.append("\(label): no secret named '\(name)' is bound to \(origin). Map it with the run's actors/secrets argument or ask the user to add it in project settings.")
            return
        }
        if needsLogin && secret.kind != .loginPassword {
            issues.append("\(label): secret '\(name)' is not a login+password secret.")
        }
        let missing = secret.kind.fields.filter { context.values.value(secretId: secret.id, field: $0) == nil }
        if !missing.isEmpty {
            issues.append("\(label): secret '\(name)' has no stored value for \(missing.map(\.rawValue).joined(separator: ", ")). Ask the user to enter it in project settings.")
        }
    }

    private mutating func checkGate(_ request: CurlScenarioRequest, label: String) {
        let path = CurlScenarioReferences.replace(request.path) { _ in "x" }
        guard let url = URL(string: origin + path) else {
            issues.append("step '\(label)': path '\(request.path)' is not a valid URL path.")
            return
        }
        if case .denied(let reason) = CurlGate.evaluate(method: request.method, url: url, hosts: context.hosts) {
            issues.append("step '\(label)' (\(request.method) \(request.path)): \(reason)")
        }
    }

    private mutating func checkReferences(_ step: CurlScenarioStep, scope: CurlScenarioScope, label: String) {
        for text in step.templateTexts {
            for reference in CurlScenarioReferences.scan(text).references where reference.kind == .secret {
                guard let real = scope.slots[reference.name], let secret = context.secret(named: real, origin: origin),
                      let field = reference.field else { continue }
                let valid = CurlSecretField(rawValue: field).map { secret.kind.fields.contains($0) } ?? false
                if !valid {
                    issues.append("step '\(label)': {{secret:\(reference.name).\(field)}} — secret '\(real)' has no '\(field)' part (it has: \(secret.kind.fields.map(\.rawValue).joined(separator: ", "))).")
                }
            }
        }
    }

    private static func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}
