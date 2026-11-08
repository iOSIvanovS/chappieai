// CurlTools.swift
// ChappieCore
//
// Executes curl_request / curl_session / curl_extract (Curl-Chappie). Access was already decided by
// ToolPolicy (thread switch + EXECUTOR project); the HOST rules (allow-list, per-host permission)
// are enforced by the engine itself, so nothing here can widen them.
//
// Secrets come from the project the call targets (ToolAuthorization writes its canonical name into
// the arguments); their VALUES are read from the Keychain only inside the engine.
// Console logs carry method and host only — never bodies, headers or values.

import Foundation

extension ToolExecutionService {

    func executeCurlTool(name: String, argsData: Data) async throws -> String {
        guard let args = try? JSONDecoder().decode([String: String].self, from: argsData) else {
            return "Error: Invalid arguments for \(name)"
        }
        let context = curlContext(project: args["project"])
        do {
            switch name {
            case "curl_request": return try await curlRequest(args, context)
            case "curl_session": return try await curlSession(args, context)
            default:             return try await curlExtract(args, context)
            }
        } catch let failure as CurlToolArguments.Failure {
            return "❌ \(name): \(failure.message)"
        } catch let error as CurlError {
            return "❌ \(name): \(error.localizedDescription)"
        }
        // CancellationError (Stop button, watchdog) propagates on purpose.
    }

    // MARK: - Context

    func curlContext(project: String?) -> CurlContext {
        let info = activeMemoryContext.projects.first { $0.name == project }
        let secrets = info.map { settings(of: $0).curlSecrets } ?? []
        return CurlContext(hosts: activeMemoryContext.curlHosts, secrets: secrets, values: CurlSecretKeychain())
    }

    /// `url` (absolute) or `host` (name or origin from the thread table) + `path`.
    private func curlURL(_ args: [String: String], _ context: CurlContext) throws -> String {
        let path = args["path"] ?? ""
        if let url = args["url"], !url.isEmpty { return url }
        guard let host = args["host"], !host.isEmpty else {
            throw CurlToolArguments.Failure(message: "Give 'url' (absolute) or 'host' (a name from the thread's host list) with 'path'.\(hostList(context))")
        }
        guard let origin = CurlEngine.shared.resolveOrigin(host, context: context) else {
            throw CurlToolArguments.Failure(message: "Unknown host '\(host)'.\(hostList(context))")
        }
        return origin + (path.isEmpty || path.hasPrefix("/") ? path : "/" + path)
    }

    func hostList(_ context: CurlContext) -> String {
        guard !context.hosts.isEmpty else { return " This thread has no hosts: ask the user to add one in thread settings." }
        return " Hosts: " + context.hosts.map { "\($0.name) = \($0.origin) [\($0.permission.rawValue)]" }.joined(separator: "; ")
    }

    private func requestSpec(_ args: [String: String], _ context: CurlContext, method: String) throws -> CurlRequestSpec {
        CurlRequestSpec(
            method: method,
            url: try curlURL(args, context),
            headers: try CurlToolArguments.headers(args),
            query: CurlToolArguments.pairs(from: try CurlToolArguments.object(args, "query")),
            body: try CurlToolArguments.body(args),
            session: args["session"],
            pick: try CurlToolArguments.pick(args),
            showAllHeaders: (args["show_headers"] ?? "").lowercased() == "all")
    }

    // MARK: - curl_request

    private func curlRequest(_ args: [String: String], _ context: CurlContext) async throws -> String {
        let method = (args["method"] ?? "GET").uppercased()
        let spec = try requestSpec(args, context, method: method)
        print("[CurlTools] 🌐 \(method) \(CurlOrigin.normalize(CurlTemplate.neutralized(spec.url)) ?? "?")")
        let response = try await CurlEngine.shared.send(spec, context: context)
        return response.render()
    }

    // MARK: - curl_session

    private func curlSession(_ args: [String: String], _ context: CurlContext) async throws -> String {
        let action = (args["action"] ?? "login").lowercased()
        switch action {
        case "login":
            let method = (args["method"] ?? "POST").uppercased()
            let request = try requestSpec(args, context, method: method)
            guard let session = request.session, !session.isEmpty else {
                throw CurlToolArguments.Failure(message: "Login needs 'session': the name of the secret (bound to this host) whose credentials are used.")
            }
            let extract = try CurlToolArguments.extractRules(try CurlToolArguments.array(args, "extract"))
            let apply = try CurlToolArguments.applyRules(try CurlToolArguments.array(args, "apply"))
            let recipe = CurlLoginRecipe(request: request, extract: extract, apply: apply)
            print("[CurlTools] 🔐 login as '\(session)'")
            let summary = try await CurlEngine.shared.login(recipe, context: context, force: CurlToolArguments.flag(args, "force"))
            return summary.render(sessionLabel: session)

        case "info", "reset":
            let origin = try requireOrigin(args, context)
            let session = args["session"]
            if action == "reset" {
                let existed = try await CurlEngine.shared.resetSession(origin: origin, session: session, context: context)
                return existed ? "Session reset for \(origin). The next request will need a login." : "There was no session to reset for \(origin)."
            }
            return render(try await CurlEngine.shared.sessionInfo(origin: origin, session: session, context: context), origin: origin)

        default:
            throw CurlToolArguments.Failure(message: "Unknown action '\(action)'. Use login, info or reset.")
        }
    }

    private func requireOrigin(_ args: [String: String], _ context: CurlContext) throws -> String {
        guard let host = args["host"] ?? args["url"], !host.isEmpty else {
            throw CurlToolArguments.Failure(message: "Give 'host' (a name from the thread's host list).\(hostList(context))")
        }
        guard let origin = CurlEngine.shared.resolveOrigin(host, context: context) else {
            throw CurlToolArguments.Failure(message: "Unknown host '\(host)'.\(hostList(context))")
        }
        return origin
    }

    private func render(_ info: CurlSessionInfo, origin: String) -> String {
        guard info.exists else { return "No session for \(origin) yet (not logged in)." }
        let variables = info.variables.isEmpty ? "none"
            : info.variables.sorted { $0.key < $1.key }.map { $0.value ? "\($0.key) (hidden)" : $0.key }.joined(separator: ", ")
        var out = "Session for \(origin): generation \(info.generation), variables: \(variables), "
        out += "cookies: \(info.cookieNames.isEmpty ? "none" : info.cookieNames.joined(separator: ", ")), "
        out += "login recipe saved: \(info.hasRecipe ? "yes (401 re-login is automatic)" : "no")."
        if let at = info.establishedAt { out += " Established \(ISO8601DateFormatter().string(from: at))." }
        return out
    }

    // MARK: - curl_extract

    private func curlExtract(_ args: [String: String], _ context: CurlContext) async throws -> String {
        let origin = try requireOrigin(args, context)
        guard let variable = args["name"], !variable.isEmpty, let from = args["from"], !from.isEmpty else {
            throw CurlToolArguments.Failure(message: "Give 'name' (variable name) and 'from' (json:path, header:Name or cookie:name).")
        }
        // Unless the model says otherwise, a variable named like a credential is hidden; an id is not.
        let sensitive = args["sensitive"].map { $0.lowercased() != "false" } ?? CurlRedactor.isSensitiveKey(variable)
        let rule = CurlExtractRule(name: variable, source: try CurlToolArguments.source(from), sensitive: sensitive)
        let result = try await CurlEngine.shared.extract(rule, origin: origin, session: args["session"], context: context)
        let shown = result.shownValue.map { "= \($0)" } ?? "(sensitive, hidden)"
        return "Saved variable '\(result.name)' \(shown). Use it as {{var:\(result.name)}} in later requests of this session."
    }
}
