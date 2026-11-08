// CurlScenarioRunner+Steps.swift
// ChappieCore
//
// Step mechanics of a scenario run: substitution, sending through the engine, checks, extraction and
// nested calls.
//
// FAILURE RULES
//   main steps : the first failed step stops the scenario (a later step would act on bad state).
//   cleanup    : every step is tried; one that needs a value that was never produced is SKIPPED and
//                reported ("nothing was created, nothing to delete"); a failing one is reported, the rest still run.
//   calls      : a failed callee fails the calling step. A callee's own cleanup is never run (root-only rule).
// CancellationError (Stop button, watchdog) always propagates; every other engine error is a step failure.

import Foundation

extension CurlScenarioRunner {

    // MARK: - Step list

    /// Returns true when every step passed (or, in cleanup, ran or was skipped without error).
    func runSteps(
        _ steps: [CurlScenarioStep], scope: inout CurlScenarioScope, depth: Int, stopOnFailure: Bool, isCleanup: Bool
    ) async throws -> Bool {
        var allPassed = true
        for step in steps {
            let ok = try await runStep(step, scope: &scope, depth: depth, isCleanup: isCleanup)
            if !ok {
                allPassed = false
                if stopOnFailure { break }
            }
        }
        return allPassed
    }

    private func runStep(_ step: CurlScenarioStep, scope: inout CurlScenarioScope, depth: Int, isCleanup: Bool) async throws -> Bool {
        switch step.action {
        case .request(let request):
            return try await runRequest(step, request, scope: &scope, depth: depth, isCleanup: isCleanup)
        case .call(let call):
            return try await runCall(step, call, scope: &scope, depth: depth)
        }
    }

    // MARK: - Request step

    private struct Prepared {
        var spec: CurlRequestSpec
        var checks: [CurlScenarioCheck]
        var missing: [String]
        var problems: [String]
    }

    private func prepare(_ request: CurlScenarioRequest, step: CurlScenarioStep, scope: CurlScenarioScope) -> Prepared {
        var missing: [String] = []
        var problems: [String] = []
        func sub(_ text: String, _ mode: CurlScenarioSubstitution.Mode, secrets: Bool = true) -> String {
            let outcome = CurlScenarioSubstitution.apply(text, mode: mode, scope: scope, allowSecrets: secrets)
            missing += outcome.missing
            problems += outcome.problems
            return outcome.text
        }

        let path = sub(request.path, .url)
        let query = request.query.map { CurlPair($0.name, sub($0.value, .raw)) }
        let headers = request.headers.map { CurlHeader($0.name, sub($0.value, .raw)) }
        var body: CurlBody?
        switch request.body {
        case .json(let text)?:        body = .json(sub(text, .json))
        case .form(let pairs)?:       body = .form(pairs.map { CurlPair($0.name, sub($0.value, .raw)) })
        case .text(let text, let type)?: body = .text(sub(text, .raw), contentType: type)
        case nil:                     body = nil
        }
        let checks = step.expect.checks.map { check -> CurlScenarioCheck in
            switch check.operation {
            case .equals(let value):   return CurlScenarioCheck(path: check.path, operation: .equals(sub(value, .raw, secrets: false)))
            case .contains(let value): return CurlScenarioCheck(path: check.path, operation: .contains(sub(value, .raw, secrets: false)))
            case .exists:              return check
            }
        }
        let session = step.actor.flatMap { scope.actors[$0] }
        let spec = CurlRequestSpec(method: request.method, url: origin + path, headers: headers, query: query, body: body, session: session)
        return Prepared(spec: spec, checks: checks, missing: unique(missing), problems: unique(problems))
    }

    private func runRequest(
        _ step: CurlScenarioStep, _ request: CurlScenarioRequest,
        scope: inout CurlScenarioScope, depth: Int, isCleanup: Bool
    ) async throws -> Bool {
        let pad = String(repeating: "  ", count: depth + 1)
        let prepared = prepare(request, step: step, scope: scope)
        let title = "\(step.id) — \(request.method) \(request.path)"

        if !prepared.missing.isEmpty && isCleanup {
            state.lines.append("\(pad)– \(title): skipped, no value for \(prepared.missing.joined(separator: ", ")) (the step that makes it did not run).")
            return true
        }
        if !prepared.missing.isEmpty || !prepared.problems.isEmpty {
            let reasons = (prepared.missing.isEmpty ? [] : ["no value for \(prepared.missing.joined(separator: ", "))"]) + prepared.problems
            state.lines.append("\(pad)✗ \(title): not sent — \(reasons.joined(separator: "; ")).")
            return false
        }

        do {
            if request.login != nil {
                return try await runLogin(step, request, prepared, scope: &scope, pad: pad, title: title)
            }
            let captured = try await engine.sendCapturing(prepared.spec, context: context)
            state.requests += 1
            return await finish(step, request, captured, checks: prepared.checks, scope: &scope, pad: pad, title: title)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CurlError {
            state.lines.append("\(pad)✗ \(title): \(await redact(error.localizedDescription, step: step, scope: scope))")
            return false
        }
    }

    /// Checks, extraction and the report line of a step that got an answer.
    private func finish(
        _ step: CurlScenarioStep, _ request: CurlScenarioRequest, _ captured: CurlCapturedResponse,
        checks: [CurlScenarioCheck], scope: inout CurlScenarioScope, pad: String, title: String
    ) async -> Bool {
        let raw = captured.raw
        var problems = CurlScenarioChecks.failures(statuses: step.expect.statuses, checks: checks, status: raw.status, body: raw.body)
        var shown: [String] = []

        if problems.isEmpty {
            for rule in request.extract {
                guard let value = CurlEngine.extractValue(rule.source, status: raw.status, headers: raw.headers, cookies: raw.cookies, body: raw.body) else {
                    problems.append("extract '\(rule.name)': nothing found at \(describe(rule.source))")
                    continue
                }
                scope.vars[rule.name] = CurlScenarioValue(text: value, sensitive: rule.sensitive)
                shown.append(display(rule.name, value, sensitive: rule.sensitive))
            }
        }

        let response = captured.response
        let head = "\(title) → \(response.status) (\(response.durationMs) ms)"
        if problems.isEmpty {
            state.lines.append("\(pad)✓ \(head)")
            for item in shown { state.lines.append("\(pad)    extracted \(item)") }
            if verbose { appendBody(response, pad: pad) }
            return true
        }
        state.lines.append("\(pad)✗ \(head)")
        for problem in problems { state.lines.append("\(pad)    • \(await redact(problem, step: step, scope: scope))") }
        appendBody(response, pad: pad)
        return false
    }

    // MARK: - Login step

    private func runLogin(
        _ step: CurlScenarioStep, _ request: CurlScenarioRequest, _ prepared: Prepared,
        scope: inout CurlScenarioScope, pad: String, title: String
    ) async throws -> Bool {
        guard let login = request.login, let session = prepared.spec.session else {
            state.lines.append("\(pad)✗ \(title): a login step needs an actor.")
            return false
        }
        let recipe = CurlLoginRecipe(request: prepared.spec, extract: login.extract, apply: login.apply)
        let summary = try await engine.login(recipe, context: context)

        if summary.reused {
            // No request was sent: values the step extracted last time live in the shared session.
            var shown: [String] = []
            for rule in request.extract {
                guard let stored = try await engine.sessionVariable(storeKey(step, rule, scope), origin: origin, session: session, context: context) else {
                    state.lines.append("\(pad)✗ \(title): the session is reused but '\(rule.name)' was never stored for it. Reset the session (curl_session action=reset) and run again.")
                    return false
                }
                scope.vars[rule.name] = CurlScenarioValue(text: stored.value, sensitive: stored.sensitive)
                shown.append(display(rule.name, stored.value, sensitive: stored.sensitive))
            }
            state.lines.append("\(pad)✓ \(title) → session reused, no request sent (generation \(summary.generation))")
            for item in shown { state.lines.append("\(pad)    extracted \(item)") }
            return true
        }

        state.requests += 1
        guard let last = try await engine.lastStoredResponse(origin: origin, session: session, context: context) else {
            state.lines.append("\(pad)✗ \(title): the login answered but the answer was not kept.")
            return false
        }
        // Redact the whole body first: a value cut by the length limit loses its closing quote,
        // and then neither the key mask nor the known-value match can find it.
        let shownBody = await engine.redactForDisplay(String(decoding: last.body, as: UTF8.self),
                                                      origin: origin, session: session, context: context)
        let captured = CurlCapturedResponse(
            response: CurlResponse(method: request.method, url: origin + request.path, status: last.status, headers: [], cookieNames: [],
                                   body: shownBody, bodyBytes: last.body.count, truncated: false, durationMs: 0, relogin: false, notes: []),
            raw: last)
        let ok = await finish(step, request, captured, checks: prepared.checks, scope: &scope, pad: pad, title: "\(title) (login, generation \(summary.generation))")
        guard ok else { return false }
        for rule in request.extract {
            if let variable = scope.vars[rule.name] {
                try await engine.storeSessionVariable(storeKey(step, rule, scope), value: variable.text, sensitive: variable.sensitive,
                                                      origin: origin, session: session, context: context)
            }
        }
        return true
    }

    // MARK: - Call step

    private func runCall(_ step: CurlScenarioStep, _ call: CurlScenarioCall, scope: inout CurlScenarioScope, depth: Int) async throws -> Bool {
        let pad = String(repeating: "  ", count: depth + 1)
        guard let callee = store.load(call.scenario) else {
            state.lines.append("\(pad)✗ \(step.id) — call \(call.scenario): scenario not found.")
            return false
        }
        switch CurlScenarioBindings.child(call: call, step: step, callee: callee, parentActors: scope.actors, parentSecrets: scope.secrets) {
        case .failure(let error):
            state.lines.append("\(pad)✗ \(step.id) — call \(call.scenario): \(error.message)")
            return false
        case .success(let child):
            var inputs: [String: String] = [:]
            for input in callee.inputs { if let value = input.defaultValue { inputs[input.name] = value } }
            var missing: [String] = []
            var problems: [String] = []
            for pair in call.with {
                let outcome = CurlScenarioSubstitution.apply(pair.value, mode: .raw, scope: scope, allowSecrets: false)
                missing += outcome.missing
                problems += outcome.problems
                inputs[pair.name] = outcome.text
            }
            if !missing.isEmpty || !problems.isEmpty {
                let reasons = (missing.isEmpty ? [] : ["no value for \(unique(missing).joined(separator: ", "))"]) + unique(problems)
                state.lines.append("\(pad)✗ \(step.id) — call \(call.scenario): not started — \(reasons.joined(separator: "; ")).")
                return false
            }

            let who = child.actors.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            state.lines.append("\(pad)↳ \(step.id) — call \(call.scenario)\(who.isEmpty ? "" : " (\(who))")")
            var childScope = CurlScenarioScope(scenario: callee, actors: child.actors, secrets: child.secrets, inputs: inputs)
            let passed = try await runSteps(callee.steps, scope: &childScope, depth: depth + 1, stopOnFailure: true, isCleanup: false)
            guard passed else { return false }

            var returned: [String] = []
            for name in call.returns {
                guard let value = childScope.vars[name] else {
                    state.lines.append("\(pad)✗ \(step.id) — call \(call.scenario): it finished but did not produce '\(name)'.")
                    return false
                }
                scope.vars["\(step.id).\(name)"] = value
                returned.append(display("\(step.id).\(name)", value.text, sensitive: value.sensitive))
            }
            if !returned.isEmpty { state.lines.append("\(pad)  returned \(returned.joined(separator: ", "))") }
            return true
        }
    }

    // MARK: - Helpers

    private func appendBody(_ response: CurlResponse, pad: String) {
        guard !response.body.isEmpty else { return }
        var body = response.body
        if body.count > Self.maxShownBody { body = String(body.prefix(Self.maxShownBody)) + "… [\(response.bodyBytes) bytes in total]" }
        state.lines.append("\(pad)    body: \(body)")
    }

    private func display(_ name: String, _ value: String, sensitive: Bool) -> String {
        if sensitive { return "\(name) (hidden)" }
        return "\(name)=\(value.count > 80 ? String(value.prefix(77)) + "..." : value)"
    }

    private func describe(_ source: CurlExtractSource) -> String {
        switch source {
        case .json(let path):   return "json:\(path)"
        case .header(let name): return "header:\(name)"
        case .cookie(let name): return "cookie:\(name)"
        }
    }

    /// Free text that may quote a response value goes through the session's redactor first.
    private func redact(_ text: String, step: CurlScenarioStep, scope: CurlScenarioScope) async -> String {
        let session = step.actor.flatMap { scope.actors[$0] }
        return await engine.redactForDisplay(text, origin: origin, session: session, context: context)
    }

    /// Where a login step's extracted value is kept in the shared session, so a reused session can serve it again.
    private func storeKey(_ step: CurlScenarioStep, _ rule: CurlExtractRule, _ scope: CurlScenarioScope) -> String {
        "scenario:\(scope.scenario.name).\(step.id).\(rule.name)"
    }

    private func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}
