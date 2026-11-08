// CurlScenarioTools.swift
// ChappieCore
//
// curl_scenario_info / curl_scenario_save / curl_scenario_delete: manage scenario FILES of a project
// (see CurlScenarios/). Access was decided by ToolPolicy (thread switch + EXECUTOR project), so these
// writes need no extra confirmation; the folder is checked by PathGuard inside CurlScenarioStore.
// Running a scenario is a separate tool (not here): these three never send a request.

import Foundation

extension ToolExecutionService {

    func executeCurlScenarioTool(name: String, argsData: Data) async -> String {
        guard let args = try? JSONDecoder().decode([String: String].self, from: argsData) else {
            return "Error: Invalid arguments for \(name)"
        }
        let store: CurlScenarioStore
        do { store = try scenarioStore(args) }
        catch let failure as CurlScenarioStore.Failure { return "❌ \(name): \(failure.message)" }
        catch { return "❌ \(name): \(error.localizedDescription)" }

        switch name {
        case "curl_scenario_info":   return scenarioInfo(args, store)
        case "curl_scenario_save":   return scenarioSave(args, store)
        default:                     return scenarioDelete(args, store)
        }
    }

    // MARK: - Folder

    func scenarioStore(_ args: [String: String]) throws -> CurlScenarioStore {
        guard let project = args["project"], let path = activeMemoryContext.projectPathMap[project], !path.isEmpty else {
            throw CurlScenarioStore.Failure(message: "The project folder is not resolved yet. Wait a moment and try again.")
        }
        return try CurlScenarioStore(root: URL(fileURLWithPath: path), folder: args["folder"] ?? "")
    }

    // MARK: - info

    private func scenarioInfo(_ args: [String: String], _ store: CurlScenarioStore) -> String {
        if let name = args["name"], !name.isEmpty { return describeOne(name, store) }

        let names: [String]
        do { names = try store.names() } catch { return "❌ curl_scenario_info: \(error.localizedDescription)" }
        guard !names.isEmpty else {
            return "No scenarios in '\(store.folder)' yet. Build a chain with curl_request, then store it with curl_scenario_save."
        }
        var lines = ["Scenarios in '\(store.folder)' (\(names.count)):"]
        for name in names {
            switch store.loadResult(name) {
            case .failure(let issues):
                lines.append("• \(name) — UNREADABLE: \(issues.messages.first ?? "invalid")")
            case .success(let s):
                lines.append("• \(name)\(s.mutates ? " [writes data]" : "") — \(s.description)")
                lines.append("    actors: \(list(s.actors)); secrets: \(list(s.secrets)); inputs: \(inputsText(s)); returns: \(list(s.returns)); calls: \(list(s.calledScenarios))")
            }
        }
        lines.append("Pass `name` to read one scenario in full.")
        return lines.joined(separator: "\n")
    }

    private func describeOne(_ name: String, _ store: CurlScenarioStore) -> String {
        guard CurlScenarioRules.isValidIdentifier(name) else { return "❌ curl_scenario_info: '\(name)' is not a valid scenario name." }
        let url: URL
        do { url = try store.fileURL(for: name) } catch { return "❌ curl_scenario_info: \(error.localizedDescription)" }
        guard let data = try? Data(contentsOf: url), data.count <= CurlScenarioRules.maxFileBytes else {
            return "❌ curl_scenario_info: scenario '\(name)' does not exist in '\(store.folder)' (or is too large)."
        }
        var out = String(decoding: data, as: UTF8.self)
        switch store.loadResult(name) {
        case .failure(let issues):
            out += "\n\n⚠️ The file does not load:\n" + issues.messages.map { "• \($0)" }.joined(separator: "\n")
        case .success(let scenario):
            let check = CurlScenarioValidator.validate(scenario) { store.load($0) }
            if !check.isValid { out += "\n\n⚠️ Problems:\n" + check.errors.map { "• \($0)" }.joined(separator: "\n") }
            let callers = store.callers(of: name)
            if !callers.isEmpty { out += "\n\nCalled by: \(callers.joined(separator: ", "))." }
        }
        return out
    }

    // MARK: - save

    private func scenarioSave(_ args: [String: String], _ store: CurlScenarioStore) -> String {
        guard let text = args["scenario"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "❌ curl_scenario_save: give 'scenario' — the whole scenario as a JSON object."
        }
        guard let json = CurlScenarioStore.canonicalJSON(from: text) else {
            return "❌ curl_scenario_save: 'scenario' is not a JSON object."
        }
        guard json.count <= CurlScenarioRules.maxFileBytes else {
            return "❌ curl_scenario_save: the scenario is larger than \(CurlScenarioRules.maxFileBytes / 1000) KB. Split it with 'call'."
        }
        let scenario: CurlScenario
        switch CurlScenarioDecoder.decode(json) {
        case .failure(let issues): return rejected(issues.messages)
        case .success(let decoded): scenario = decoded
        }
        if let wanted = args["name"], !wanted.isEmpty, wanted != scenario.name {
            return "❌ curl_scenario_save: 'name' is '\(wanted)' but the scenario's own name is '\(scenario.name)'. Make them equal."
        }

        let lookup: CurlScenarioValidator.Lookup = { $0 == scenario.name ? scenario : store.load($0) }
        let check = CurlScenarioValidator.validate(scenario, lookup: lookup)
        guard check.isValid else { return rejected(check.errors) }

        // Changing the contract (inputs, returns, actors) can break scenarios that call this one.
        let broken = store.callers(of: scenario.name).compactMap { callerName -> String? in
            guard let caller = store.load(callerName) else { return nil }
            let problems = CurlScenarioValidator.validate(caller, lookup: lookup).errors
            return problems.isEmpty ? nil : "\(callerName): \(problems[0])"
        }

        let replaced: Bool
        do { replaced = try store.write(name: scenario.name, json: json) }
        catch let failure as CurlScenarioStore.Failure { return "❌ curl_scenario_save: \(failure.message)" }
        catch { return "❌ curl_scenario_save: \(error.localizedDescription)" }
        print("[CurlScenarios] 💾 \(replaced ? "replaced" : "saved") \(scenario.name) in \(store.folder)")

        var out = "✅ \(replaced ? "Replaced" : "Saved") scenario '\(scenario.name)' at \(store.folder)/\(scenario.name).json "
        out += "(\(scenario.steps.count) steps, \(scenario.cleanup.count) cleanup, call depth \(check.depth), \(scenario.mutates ? "writes data" : "read-only"))."
        if !broken.isEmpty {
            out += "\n⚠️ These scenarios call it and no longer validate; fix them next:\n" + broken.map { "• \($0)" }.joined(separator: "\n")
        }
        return out
    }

    private func rejected(_ problems: [String]) -> String {
        "❌ curl_scenario_save: not saved. Fix these and send the whole scenario again:\n" + problems.map { "• \($0)" }.joined(separator: "\n")
    }

    // MARK: - delete

    private func scenarioDelete(_ args: [String: String], _ store: CurlScenarioStore) -> String {
        guard let name = args["name"], !name.isEmpty else { return "❌ curl_scenario_delete: give 'name'." }
        guard store.exists(name) else { return "❌ curl_scenario_delete: scenario '\(name)' does not exist in '\(store.folder)'." }
        let callers = store.callers(of: name)
        guard callers.isEmpty else {
            return "❌ curl_scenario_delete: not deleted — still called by: \(callers.joined(separator: ", ")). Change or delete those first."
        }
        do { try store.delete(name) }
        catch let failure as CurlScenarioStore.Failure { return "❌ curl_scenario_delete: \(failure.message)" }
        catch { return "❌ curl_scenario_delete: \(error.localizedDescription)" }
        print("[CurlScenarios] 🗑️ deleted \(name) from \(store.folder)")
        return "✅ Deleted scenario '\(name)' from \(store.folder)."
    }

    // MARK: - Text helpers

    private func list(_ items: [String]) -> String { items.isEmpty ? "none" : items.joined(separator: ", ") }

    private func inputsText(_ s: CurlScenario) -> String {
        s.inputs.isEmpty ? "none" : s.inputs.map { $0.isRequired ? $0.name : "\($0.name)=\($0.defaultValue ?? "")" }.joined(separator: ", ")
    }
}
