// CurlEngine+Scenario.swift
// ChappieCore
//
// The few engine entry points the scenario runner needs beyond send/login: read a session variable,
// look at the last stored answer of a session, and redact free text the way a response is redacted.
// Raw values returned here stay inside the app; the runner decides what the model sees.

import Foundation

extension CurlEngine {

    /// Value of a session variable (set by a login recipe or curl_extract) with its sensitivity flag.
    func sessionVariable(
        _ name: String, origin: String, session: String?, context: CurlContext
    ) throws -> (value: String, sensitive: Bool)? {
        let key = try sessionKey(name: session, origin: origin, context: context)
        guard let variable = sessions[key]?.variables[name] else { return nil }
        return (variable.value, variable.sensitive)
    }

    /// Keeps a value a scenario step extracted next to the session's own variables (so a reused session can serve it).
    func storeSessionVariable(
        _ name: String, value: String, sensitive: Bool, origin: String, session: String?, context: CurlContext
    ) throws {
        let key = try sessionKey(name: session, origin: origin, context: context)
        sessions[key, default: CurlSession()].variables[name] = CurlVariable(value: value, sensitive: sensitive)
    }

    /// The last answer stored for the session (raw body included).
    func lastStoredResponse(origin: String, session: String?, context: CurlContext) throws -> CurlRawResponse? {
        let key = try sessionKey(name: session, origin: origin, context: context)
        guard let last = sessions[key]?.last else { return nil }
        return CurlRawResponse(status: last.status, headers: last.headers, body: last.body, cookies: last.cookies)
    }

    /// Removes every known secret, token and cookie value of the session from `text`.
    /// Falls back to the anonymous session's view when the session name cannot be resolved.
    func redactForDisplay(_ text: String, origin: String, session: String?, context: CurlContext) -> String {
        let key = (try? sessionKey(name: session, origin: origin, context: context)) ?? .anonymous(origin: origin)
        return makeRedactor(context: context, origin: origin, key: key).redactBody(text)
    }
}
