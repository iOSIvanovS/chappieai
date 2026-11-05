// CurlEngine.swift
// ChappieCore
//
// Core of Curl-Chappie: an app-wide actor that sends HTTP requests on behalf of the agent.
// Split by responsibility:
//   CurlEngine.swift         — state, public API (send / extract / info / reset), 401 handling
//   CurlEngine+Prepare.swift — template substitution, allow-list gate, building URLRequest
//   CurlEngine+Login.swift   — login recipe execution, single-flight, extraction
//
// SHARED SESSIONS: one instance serves every thread and project. Sessions are keyed by
// origin + fingerprint of the credential values (see CurlSessionKey), so projects that use
// the same credentials for the same host reuse one token instead of knocking each other out.
//
// The engine never returns an unredacted secret or token to its caller.

import Foundation

public actor CurlEngine {

    /// The one engine of the app: sessions are shared by every thread and project through it.
    public static let shared = CurlEngine()

    public static let requestsPerMinute = 60
    static let maxDisplayedBodyChars = 60_000
    static let maxRequestBodyBytes = 1_000_000

    let transport: any CurlTransport
    let now: @Sendable () -> Date
    let rateLimit: Int

    var sessions: [CurlSessionKey: CurlSession] = [:]
    var inflightLogins: [CurlSessionKey: Task<CurlLoginSummary, Error>] = [:]
    private var sentAt: [Date] = []

    public init(
        transport: any CurlTransport = URLSessionCurlTransport(),
        rateLimit: Int = CurlEngine.requestsPerMinute,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.rateLimit = rateLimit
        self.now = now
    }

    // MARK: - Send

    public func send(_ spec: CurlRequestSpec, context: CurlContext) async throws -> CurlResponse {
        let origin = try Self.templateOrigin(spec.url)
        let key = try sessionKey(name: spec.session, origin: origin, context: context)

        var relogin = false
        var attempt = 0
        while true {
            let session = sessions[key]
            let usedGeneration = session?.generation ?? 0
            let prepared = try prepare(spec, context: context, session: session, applyAuth: true)

            let started = now()
            let raw = try await transmit(prepared.request)
            record(raw, key: key)

            if raw.status == 401, attempt == 0, !prepared.isLogin, let recipe = sessions[key]?.recipe {
                attempt = 1
                _ = try await refreshLogin(key: key, recipe: recipe, context: context,
                                           expectedGeneration: usedGeneration)
                relogin = true
                continue
            }

            let elapsed = Int(now().timeIntervalSince(started) * 1000)
            return buildResponse(raw, prepared: prepared, key: key, context: context,
                                 durationMs: max(elapsed, 0), relogin: relogin,
                                 hadRecipe: sessions[key]?.recipe != nil, sessionName: spec.session)
        }
    }

    // MARK: - Session helpers

    /// Saves a value from the last response of the session into its variables.
    public func extract(
        _ rule: CurlExtractRule, origin: String, session: String?, context: CurlContext
    ) throws -> CurlExtracted {
        let origin = try requireListedOrigin(origin, context: context)
        guard Self.isValidVariableName(rule.name) else {
            throw CurlError.invalidRequest("Variable name '\(rule.name)' may contain only letters, digits, '_' and '-'.")
        }
        let key = try sessionKey(name: session, origin: origin, context: context)
        guard let last = sessions[key]?.last else {
            throw CurlError.noSession("No previous response is stored for this session yet. Send a request first.")
        }
        guard let value = Self.extractValue(rule.source, status: last.status, headers: last.headers,
                                            cookies: last.cookies, body: last.body) else {
            throw CurlError.invalidRequest("Nothing found for '\(rule.name)' in the last response of this session.")
        }
        sessions[key, default: CurlSession()].variables[rule.name] = CurlVariable(value: value, sensitive: rule.sensitive)
        let redactor = makeRedactor(context: context, origin: origin, key: key)
        return CurlExtracted(name: rule.name, shownValue: rule.sensitive ? nil : redactor.redact(value))
    }

    public func sessionInfo(origin: String, session: String?, context: CurlContext) throws -> CurlSessionInfo {
        let origin = try requireListedOrigin(origin, context: context)
        let key = try sessionKey(name: session, origin: origin, context: context)
        guard let s = sessions[key] else {
            return CurlSessionInfo(exists: false, generation: 0, variables: [:], cookieNames: [],
                                   establishedAt: nil, hasRecipe: false)
        }
        return CurlSessionInfo(
            exists: true, generation: s.generation,
            variables: s.variables.mapValues { $0.sensitive },
            cookieNames: s.cookies.map(\.name).sorted(),
            establishedAt: s.establishedAt, hasRecipe: s.recipe != nil)
    }

    @discardableResult
    public func resetSession(origin: String, session: String?, context: CurlContext) throws -> Bool {
        let origin = try requireListedOrigin(origin, context: context)
        let key = try sessionKey(name: session, origin: origin, context: context)
        inflightLogins[key]?.cancel()
        inflightLogins[key] = nil
        return sessions.removeValue(forKey: key) != nil
    }

    /// Accepts a host name from the thread table or an origin/URL; returns the listed origin.
    public nonisolated func resolveOrigin(_ nameOrURL: String, context: CurlContext) -> String? {
        let trimmed = nameOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let byName = context.hosts.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return byName.origin
        }
        guard let origin = CurlOrigin.normalize(trimmed) else { return nil }
        return context.hosts.contains { $0.origin == origin } ? origin : nil
    }

    // MARK: - Internals

    func requireListedOrigin(_ raw: String, context: CurlContext) throws -> String {
        guard let origin = resolveOrigin(raw, context: context) else {
            throw CurlError.denied("'\(raw)' is not a host of this thread's Curl-Chappie list.")
        }
        return origin
    }

    func sessionKey(name: String?, origin: String, context: CurlContext) throws -> CurlSessionKey {
        guard let name, !name.isEmpty else { return .anonymous(origin: origin) }
        guard let secret = context.secret(named: name, origin: origin) else {
            throw CurlError.noSession("No secret named '\(name)' is bound to \(origin). The session name must be a secret defined for this host in project settings (or omit it for an anonymous session).")
        }
        var parts: [(field: String, value: String)] = []
        var missing: [String] = []
        for field in secret.kind.fields {
            if let value = context.values.value(secretId: secret.id, field: field) {
                parts.append((field.rawValue, value))
            } else {
                missing.append(field.rawValue)
            }
        }
        guard missing.isEmpty else { throw CurlError.missingSecretValue(secret: name, fields: missing) }
        return CurlSessionKey(origin: origin, fingerprint: CurlSessionKey.fingerprint(of: parts))
    }

    /// Rate limit, then the network. URLSession cancellation becomes CancellationError so the
    /// tool watchdog and the Stop button behave the same as for every other tool.
    func transmit(_ request: URLRequest) async throws -> CurlRawResponse {
        let cutoff = now().addingTimeInterval(-60)
        sentAt.removeAll { $0 < cutoff }
        guard sentAt.count < rateLimit else { throw CurlError.rateLimited(limit: rateLimit) }
        sentAt.append(now())

        do {
            return try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw CurlError.transport("Network error: \(error.localizedDescription) (code \(error.code.rawValue))")
        }
    }

    func record(_ raw: CurlRawResponse, key: CurlSessionKey) {
        var session = sessions[key] ?? CurlSession()
        session.cookies = CurlCookieJar.merge(session.cookies, raw.cookies, now: now())
        session.last = CurlLastResponse(status: raw.status, headers: raw.headers, body: raw.body, cookies: raw.cookies)
        sessions[key] = session
    }

    func makeRedactor(context: CurlContext, origin: String, key: CurlSessionKey) -> CurlRedactor {
        var entries = context.redactionEntries(origin: origin)
        if let session = sessions[key] {
            for (name, variable) in session.variables where variable.sensitive {
                entries.append(("var:\(name)", variable.value))
            }
            for cookie in session.cookies {
                entries.append(("cookie:\(cookie.name)", cookie.value))
            }
        }
        return CurlRedactor(entries: entries)
    }

    private func buildResponse(
        _ raw: CurlRawResponse, prepared: CurlPrepared, key: CurlSessionKey, context: CurlContext,
        durationMs: Int, relogin: Bool, hadRecipe: Bool, sessionName: String?
    ) -> CurlResponse {
        let redactor = makeRedactor(context: context, origin: key.origin, key: key)
        var notes: [String] = []

        let contentType = raw.header("Content-Type") ?? ""
        let isHead = prepared.request.httpMethod == "HEAD"
        var text: String
        if isHead || raw.body.isEmpty {
            text = ""
        } else if Self.isTextual(contentType: contentType, body: raw.body),
                  let decoded = String(data: raw.body, encoding: .utf8) {
            text = redactor.redactBody(decoded)
        } else if Self.isTextual(contentType: contentType, body: raw.body) {
            text = redactor.redactBody(String(decoding: raw.body, as: UTF8.self))
        } else {
            text = "<binary body omitted: \(raw.body.count) bytes, Content-Type: \(contentType.isEmpty ? "unknown" : contentType)>"
            notes.append("Binary and file bodies are not shown (file download is not supported).")
        }

        var truncated = raw.truncated
        if text.count > Self.maxDisplayedBodyChars {
            text = String(text.prefix(Self.maxDisplayedBodyChars))
            truncated = true
        }

        if raw.status == 401 {
            if sessionName == nil || sessionName?.isEmpty == true {
                notes.append("401 Unauthorized. This request was sent without a session; pass the session name and log in with curl_session if the host needs authorization.")
            } else if !hadRecipe {
                notes.append("401 Unauthorized and no login recipe is stored for this session. Log in with curl_session first.")
            }
        }
        if (300..<400).contains(raw.status), let location = raw.header("Location") {
            notes.append("Redirect is not followed automatically. Location: \(redactor.redact(location))")
        }

        return CurlResponse(
            method: prepared.request.httpMethod ?? "",
            url: redactor.redact(prepared.url.absoluteString),
            status: raw.status,
            headers: redactor.redactHeaders(raw.headers),
            cookieNames: raw.cookies.map(\.name),
            body: text,
            bodyBytes: raw.body.count,
            truncated: truncated,
            durationMs: durationMs,
            relogin: relogin,
            notes: notes)
    }

    static func isTextual(contentType: String, body: Data) -> Bool {
        let lower = contentType.lowercased()
        if lower.isEmpty { return String(data: body.prefix(2048), encoding: .utf8) != nil }
        let textual = ["text/", "json", "xml", "javascript", "x-www-form-urlencoded", "html", "yaml", "csv"]
        return textual.contains { lower.contains($0) }
    }

    static func isValidVariableName(_ name: String) -> Bool {
        CurlSecret.isValidName(name)
    }
}
