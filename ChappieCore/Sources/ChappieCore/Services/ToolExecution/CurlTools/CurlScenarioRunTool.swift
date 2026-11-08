// CurlScenarioRunTool.swift
// ChappieCore
//
// curl_scenario_run: executes a stored scenario (see CurlScenarios/Runner). Access was decided by
// ToolPolicy (thread switch + EXECUTOR project) and every request still passes the host gate inside the
// engine; the runner additionally checks ALL steps (cleanup included) against the gate before it sends anything.
// Console logs carry the scenario name and counts only — never bodies, headers or values.

import Foundation

extension ToolExecutionService {

    func executeCurlScenarioRun(argsData: Data) async throws -> String {
        guard let args = try? JSONDecoder().decode([String: String].self, from: argsData) else {
            return "Error: Invalid arguments for curl_scenario_run"
        }
        do {
            let store = try scenarioStore(args)
            let context = curlContext(project: args["project"])
            guard let name = args["name"], !name.isEmpty else {
                return "❌ curl_scenario_run: give 'name' (see curl_scenario_info) and 'host'.\(hostList(context))"
            }
            guard let host = args["host"], !host.isEmpty else {
                return "❌ curl_scenario_run: give 'host', a name from the thread's host list.\(hostList(context))"
            }
            let request = CurlScenarioRunRequest(
                scenario: name, host: host,
                actors: try stringMap(args, "actors"),
                secrets: try stringMap(args, "secrets"),
                inputs: try stringMap(args, "inputs"),
                verbose: CurlToolArguments.flag(args, "verbose"),
                dryRun: CurlToolArguments.flag(args, "dry_run"))

            print("[CurlScenarios] ▶ run \(name) (dry: \(request.dryRun))")
            let report = try await CurlScenarioRunner.run(request, store: store, context: context, engine: CurlEngine.shared)
            print("[CurlScenarios] ■ \(name) refused=\(report.refused) passed=\(report.passed) requests=\(report.requestsSent)")
            return report.text
        } catch let failure as CurlScenarioStore.Failure {
            return "❌ curl_scenario_run: \(failure.message)"
        } catch let failure as CurlToolArguments.Failure {
            return "❌ curl_scenario_run: \(failure.message)"
        } catch let error as CurlError {
            return "❌ curl_scenario_run: \(error.localizedDescription)"
        }
        // CancellationError (Stop button, watchdog) propagates on purpose.
    }

    /// {"slot": "value"} as JSON text; scalars become strings. Absent = empty.
    private func stringMap(_ args: [String: String], _ key: String) throws -> [String: String] {
        let object = try CurlToolArguments.object(args, key)
        return Dictionary(uniqueKeysWithValues: object.map { ($0.key, CurlToolArguments.text(of: $0.value)) })
    }
}
