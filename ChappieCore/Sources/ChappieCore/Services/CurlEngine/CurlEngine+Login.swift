// CurlEngine+Login.swift
// ChappieCore
//
// Executes a login recipe and keeps the resulting tokens in the shared session store.
//
// SINGLE-FLIGHT + GENERATION: concurrent callers that need the same session wait for ONE login
// request. A 401 only triggers a new login if the session generation the failed request used is
// still current; if a neighbour already refreshed the session the request is just repeated.
// This keeps servers with "one session per user" from invalidating each other's tokens.

import Foundation

extension CurlEngine {

    public func login(_ recipe: CurlLoginRecipe, context: CurlContext, force: Bool = false) async throws -> CurlLoginSummary {
        guard !recipe.extract.isEmpty else {
            throw CurlError.invalidRequest("A login recipe needs at least one extraction rule (where the token is in the response).")
        }
        for rule in recipe.extract where !Self.isValidVariableName(rule.name) {
            throw CurlError.invalidRequest("Variable name '\(rule.name)' may contain only letters, digits, '_' and '-'.")
        }
        for rule in recipe.apply where rule.header.trimmingCharacters(in: .whitespaces).isEmpty {
            throw CurlError.invalidRequest("An apply rule needs a header name.")
        }

        let origin = try Self.templateOrigin(recipe.request.url)
        let key = try sessionKey(name: recipe.request.session, origin: origin, context: context)

        if !force, var existing = sessions[key], existing.generation > 0, existing.hasAllVariables(of: recipe.extract) {
            existing.recipe = recipe
            sessions[key] = existing
            return summary(of: existing, status: existing.last?.status ?? 0, rules: recipe.extract, reused: true)
        }
        return try await refreshLogin(key: key, recipe: recipe, context: context, expectedGeneration: nil)
    }

    func refreshLogin(
        key: CurlSessionKey, recipe: CurlLoginRecipe, context: CurlContext, expectedGeneration: Int?
    ) async throws -> CurlLoginSummary {
        if let running = inflightLogins[key] {
            return try await running.value
        }
        if let expected = expectedGeneration, let current = sessions[key], current.generation != expected {
            return summary(of: current, status: current.last?.status ?? 0, rules: recipe.extract, reused: true)
        }
        let task = Task { try await self.runLogin(key: key, recipe: recipe, context: context) }
        inflightLogins[key] = task
        defer { inflightLogins[key] = nil }
        return try await task.value
    }

    private func runLogin(
        key: CurlSessionKey, recipe: CurlLoginRecipe, context: CurlContext
    ) async throws -> CurlLoginSummary {
        let prepared = try prepare(recipe.request, context: context, session: sessions[key], applyAuth: false)
        guard prepared.origin == key.origin else {
            throw CurlError.invalidRequest("Login request must go to the same host as the session.")
        }

        let raw = try await transmit(prepared.request)
        record(raw, key: key)

        guard (200..<300).contains(raw.status) else {
            let redactor = makeRedactor(context: context, origin: key.origin, key: key)
            let body = String(decoding: raw.body.prefix(600), as: UTF8.self)
            throw CurlError.loginFailed("Login failed: HTTP \(raw.status). Response: \(redactor.redactBody(body))")
        }

        var found: [String: CurlVariable] = [:]
        var missing: [String] = []
        for rule in recipe.extract {
            if let value = Self.extractValue(rule.source, status: raw.status, headers: raw.headers,
                                             cookies: raw.cookies, body: raw.body) {
                found[rule.name] = CurlVariable(value: value, sensitive: rule.sensitive)
            } else {
                missing.append(rule.name)
            }
        }
        guard missing.isEmpty else {
            let redactor = makeRedactor(context: context, origin: key.origin, key: key)
            let body = String(decoding: raw.body.prefix(600), as: UTF8.self)
            throw CurlError.loginFailed("Login answered HTTP \(raw.status), but these values were not found: \(missing.joined(separator: ", ")). Check the extraction paths against the response: \(redactor.redactBody(body))")
        }

        var session = sessions[key] ?? CurlSession()
        for (name, variable) in found { session.variables[name] = variable }
        session.generation += 1
        session.establishedAt = now()
        session.recipe = recipe
        sessions[key] = session
        return summary(of: session, status: raw.status, rules: recipe.extract, reused: false)
    }

    private func summary(of session: CurlSession, status: Int, rules: [CurlExtractRule], reused: Bool) -> CurlLoginSummary {
        let stored = rules.compactMap { rule -> String? in
            guard let variable = session.variables[rule.name] else { return nil }
            return variable.sensitive ? "\(rule.name) (hidden)" : "\(rule.name)=\(variable.value.prefix(80))"
        }
        return CurlLoginSummary(
            status: status, storedVariables: stored,
            cookieNames: session.cookies.map(\.name).sorted(),
            generation: session.generation, reused: reused)
    }

    // MARK: - Extraction

    static func extractValue(
        _ source: CurlExtractSource, status: Int, headers: [CurlHeader], cookies: [CurlCookie], body: Data
    ) -> String? {
        switch source {
        case .json(let path):
            return CurlJSONPath.extract(path, from: body)
        case .header(let name):
            return headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        case .cookie(let name):
            return cookies.first { $0.name == name }?.value
        }
    }
}
