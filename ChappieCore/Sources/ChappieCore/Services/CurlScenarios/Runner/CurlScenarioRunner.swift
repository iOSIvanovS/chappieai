// CurlScenarioRunner.swift
// ChappieCore
//
// Runs a stored scenario on one host. Entry point and report assembly; the step mechanics are in
// CurlScenarioRunner+Steps.swift.
//
// ORDER: load and validate -> resolve the host -> PREFLIGHT (nothing is sent if any step that will run,
// including the ROOT cleanup, would be refused) -> main steps (stop at the first failure) -> ROOT cleanup
// (always, even after a failure; cleanup of called scenarios never runs, see the cleanup rule) -> report.
//
// The model sees a compact report: one line per step, and the redacted body only for a failed step
// (or every step when `verbose`). Values of sensitive variables never appear.

import Foundation

final class CurlScenarioRunState {
    var lines: [String] = []
    var requests = 0
    var cleanupProblems: [String] = []
}

struct CurlScenarioRunner {

    let engine: CurlEngine
    let store: CurlScenarioStore
    let context: CurlContext
    let origin: String
    let verbose: Bool
    let state = CurlScenarioRunState()

    static let maxShownBody = 1_500

    // MARK: - Entry

    static func run(
        _ request: CurlScenarioRunRequest, store: CurlScenarioStore, context: CurlContext, engine: CurlEngine
    ) async throws -> CurlScenarioRunReport {
        func refuse(_ lines: [String]) -> CurlScenarioRunReport {
            CurlScenarioRunReport(text: "❌ curl_scenario_run: not started, nothing was sent.\n" + lines.joined(separator: "\n"),
                                  refused: true, passed: false, requestsSent: 0)
        }

        guard CurlScenarioRules.isValidIdentifier(request.scenario) else {
            return refuse(["'\(request.scenario)' is not a valid scenario name."])
        }
        let root: CurlScenario
        switch store.loadResult(request.scenario) {
        case .failure(let issues): return refuse(issues.messages.map { "• \($0)" })
        case .success(let loaded): root = loaded
        }
        let check = CurlScenarioValidator.validate(root) { store.load($0) }
        guard check.isValid else {
            return refuse(["The scenario does not validate; fix it with curl_scenario_save:"] + check.errors.map { "• \($0)" })
        }
        guard let origin = engine.resolveOrigin(request.host, context: context) else {
            let hosts = context.hosts.isEmpty
                ? "This thread has no hosts: ask the user to add one in thread settings."
                : "Hosts: " + context.hosts.map { "\($0.name) = \($0.origin) [\($0.permission.rawValue)]" }.joined(separator: "; ")
            return refuse(["Unknown host '\(request.host)'. \(hosts)"])
        }

        let plan: CurlScenarioPreflight.Plan
        switch CurlScenarioPreflight.check(request: request, root: root, store: store, context: context, origin: origin) {
        case .failure(let issues): return refuse(["Preflight failed:"] + issues.messages.map { "• \($0)" })
        case .success(let ok): plan = ok
        }

        let runner = CurlScenarioRunner(engine: engine, store: store, context: context, origin: origin, verbose: request.verbose)
        let hostName = context.hosts.first { $0.origin == origin }?.name ?? origin
        var header = ["▶ \(root.name) on \(hostName) (\(origin))\(plan.writesData ? " — WRITES DATA" : " — read-only")"]
        header.append("  \(describe(plan.scope))")
        if request.dryRun {
            header.append("Dry run: preflight passed (\(plan.scenarioCount) scenario(s), up to \(plan.maxRequests) request(s), every step incl. cleanup is allowed by the host). Nothing was sent.")
            return CurlScenarioRunReport(text: header.joined(separator: "\n"), refused: false, passed: true, requestsSent: 0)
        }
        return try await runner.execute(plan: plan, header: header)
    }

    // MARK: - Execution

    private func execute(plan: CurlScenarioPreflight.Plan, header: [String]) async throws -> CurlScenarioRunReport {
        let started = Date()
        var scope = plan.scope
        let root = scope.scenario

        state.lines.append("Steps:")
        let passed = try await runSteps(root.steps, scope: &scope, depth: 0, stopOnFailure: true, isCleanup: false)

        if !root.cleanup.isEmpty {
            state.lines.append("Cleanup:")
            let cleaned = try await runSteps(root.cleanup, scope: &scope, depth: 0, stopOnFailure: false, isCleanup: true)
            if !cleaned { state.cleanupProblems.append("one or more cleanup steps failed") }
        }

        var out = header + state.lines
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        out.append("Result: \(passed ? "PASSED ✅" : "FAILED ❌") — \(state.requests) request(s), \(seconds) s.")
        if !state.cleanupProblems.isEmpty {
            out.append("⚠️ Cleanup did not fully succeed: test data may remain on the server. See the cleanup lines above.")
        } else if !root.cleanup.isEmpty {
            out.append("Cleanup ran.")
        }
        return CurlScenarioRunReport(text: out.joined(separator: "\n"), refused: false, passed: passed, requestsSent: state.requests)
    }

    private static func describe(_ scope: CurlScenarioScope) -> String {
        var parts: [String] = []
        if !scope.actors.isEmpty { parts.append("actors: " + scope.actors.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")) }
        if !scope.secrets.isEmpty { parts.append("secrets: " + scope.secrets.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")) }
        if !scope.inputs.isEmpty { parts.append("inputs: " + scope.inputs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")) }
        return parts.isEmpty ? "no actors, secrets or inputs" : parts.joined(separator: "; ")
    }
}
