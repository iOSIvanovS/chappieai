// CurlEngine+Prepare.swift
// ChappieCore
//
// Turns a CurlRequestSpec into a URLRequest: validates the target, runs the allow-list gate,
// substitutes {{secret:...}} / {{var:...}} and adds session authorization.
//
// ORDER MATTERS: the origin is taken from the TEMPLATE (placeholders are forbidden in the
// scheme and host), secrets are resolved against that origin, and the gate is evaluated on the
// FINAL URL. A substituted value can therefore never redirect a request to another host.

import Foundation

struct CurlPrepared {
    var request: URLRequest
    var url: URL
    var origin: String
    var isLogin: Bool
}

extension CurlEngine {

    private static let forbiddenHeaders: Set<String> = [
        "host", "content-length", "transfer-encoding", "connection", "cookie", "upgrade", "te", "trailer"
    ]

    /// Origin of a URL template. Placeholders are only allowed after the host.
    static func templateOrigin(_ template: String) throws -> String {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        if let schemeEnd = trimmed.range(of: "://") {
            let authority = trimmed[schemeEnd.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            if authority.contains("{") || authority.contains("}") {
                throw CurlError.invalidRequest("Placeholders are not allowed in the scheme or host of the URL.")
            }
        }
        guard let origin = CurlOrigin.normalize(CurlTemplate.neutralized(trimmed)) else {
            throw CurlError.invalidRequest("Invalid URL '\(template)': it must be an absolute http(s) URL with a host and no embedded credentials.")
        }
        return origin
    }

    func prepare(
        _ spec: CurlRequestSpec, context: CurlContext, session: CurlSession?, applyAuth: Bool
    ) throws -> CurlPrepared {
        let method = spec.method.trimmingCharacters(in: .whitespaces).uppercased()
        let origin = try Self.templateOrigin(spec.url)

        var unresolved: [String] = []
        func collect(_ result: CurlSubstitution) -> String {
            unresolved.append(contentsOf: result.unresolved)
            return result.text
        }
        let resolver: (CurlReference) -> String? = { ref in
            switch ref.kind {
            case .secret:   return context.secretValue(ref, origin: origin)
            case .variable: return session?.variables[ref.name]?.value
            }
        }

        // URL
        let urlText = collect(CurlTemplate.substitute(
            spec.url.trimmingCharacters(in: .whitespacesAndNewlines), mode: .urlComponent, resolver: resolver))

        // Headers
        var headers: [CurlHeader] = []
        for header in spec.headers {
            let name = header.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, Self.isHeaderToken(name) else {
                throw CurlError.invalidRequest("Invalid header name '\(header.name)'.")
            }
            if Self.forbiddenHeaders.contains(name.lowercased()) {
                throw CurlError.invalidRequest("Header '\(name)' is managed by Curl-Chappie and cannot be set manually (cookies come from the session).")
            }
            let value = collect(CurlTemplate.substitute(header.value, mode: .raw, resolver: resolver))
            try Self.checkHeaderValue(value, name: name)
            headers.append(CurlHeader(name, value))
        }

        // Query pairs
        var queryPairs: [(String, String)] = []
        for pair in spec.query {
            let name = collect(CurlTemplate.substitute(pair.name, mode: .raw, resolver: resolver))
            let value = collect(CurlTemplate.substitute(pair.value, mode: .raw, resolver: resolver))
            queryPairs.append((name, value))
        }

        // Body
        var bodyData: Data?
        var bodyContentType: String?
        if let body = spec.body {
            guard method != "GET", method != "HEAD" else {
                throw CurlError.invalidRequest("\(method) requests cannot carry a body.")
            }
            switch body {
            case .json(let text):
                bodyData = Data(collect(CurlTemplate.substitute(text, mode: .jsonString, resolver: resolver)).utf8)
                bodyContentType = "application/json"
            case .form(let pairs):
                var encodedPairs: [String] = []
                for pair in pairs {
                    let n = collect(CurlTemplate.substitute(pair.name, mode: .raw, resolver: resolver))
                    let v = collect(CurlTemplate.substitute(pair.value, mode: .raw, resolver: resolver))
                    encodedPairs.append("\(CurlEncoding.percent(n))=\(CurlEncoding.percent(v))")
                }
                bodyData = Data(encodedPairs.joined(separator: "&").utf8)
                bodyContentType = "application/x-www-form-urlencoded"
            case .text(let text, let contentType):
                bodyData = Data(collect(CurlTemplate.substitute(text, mode: .raw, resolver: resolver)).utf8)
                bodyContentType = contentType.isEmpty ? "text/plain; charset=utf-8" : contentType
            }
            if let data = bodyData, data.count > Self.maxRequestBodyBytes {
                throw CurlError.invalidRequest("Request body is larger than \(Self.maxRequestBodyBytes) bytes.")
            }
        }

        try Self.reportUnresolved(unresolved, context: context, origin: origin)

        // Final URL
        guard var comps = URLComponents(string: urlText) else {
            throw CurlError.invalidRequest("URL is not valid after substitution.")
        }
        comps.fragment = nil
        if !queryPairs.isEmpty {
            let extra = queryPairs
                .map { "\(CurlEncoding.percent($0.0))=\(CurlEncoding.percent($0.1))" }
                .joined(separator: "&")
            comps.percentEncodedQuery = [comps.percentEncodedQuery, extra]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "&")
        }
        guard let url = comps.url, CurlOrigin.origin(of: url) == origin else {
            throw CurlError.invalidRequest("The URL resolved to a different host than the template; refusing to send.")
        }

        // Allow-list gate
        let access = CurlGate.evaluate(method: method, url: url, hosts: context.hosts)
        guard case .allowed(_, let isLogin) = access else {
            if case .denied(let reason) = access { throw CurlError.denied(reason) }
            throw CurlError.denied("Request denied.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = bodyData
        for header in headers { request.setValue(header.value, forHTTPHeaderField: header.name) }
        if let type = bodyContentType, request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue(type, forHTTPHeaderField: "Content-Type")
        }
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        }
        request.setValue("Chappie/1.0 (Curl-Chappie)", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false

        if let session {
            if applyAuth, let recipe = session.recipe {
                for rule in recipe.apply where request.value(forHTTPHeaderField: rule.header) == nil {
                    let result = CurlTemplate.substitute(rule.template, mode: .raw) { ref in
                        ref.kind == .variable ? session.variables[ref.name]?.value : nil
                    }
                    guard result.unresolved.isEmpty else {
                        throw CurlError.noSession("The session has no value for \(result.unresolved.joined(separator: ", ")). Log in again with curl_session (force=true).")
                    }
                    try Self.checkHeaderValue(result.text, name: rule.header)
                    request.setValue(result.text, forHTTPHeaderField: rule.header)
                }
            }
            if let cookie = CurlCookieJar.header(session.cookies, path: url.path.isEmpty ? "/" : url.path,
                                                 isHTTPS: url.scheme == "https", now: now()) {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
        }

        return CurlPrepared(request: request, url: url, origin: origin, isLogin: isLogin)
    }

    // MARK: - Helpers

    private static func isHeaderToken(_ name: String) -> Bool {
        name.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39) || (scalar.value >= 0x41 && scalar.value <= 0x5A) ||
            (scalar.value >= 0x61 && scalar.value <= 0x7A) || "!#$%&'*+-.^_`|~".unicodeScalars.contains(scalar)
        }
    }

    /// Rejects CR, LF and NUL: otherwise a substituted value could inject extra headers.
    private static func checkHeaderValue(_ value: String, name: String) throws {
        if value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) {
            throw CurlError.invalidRequest("Header '\(name)' contains a line break or NUL character.")
        }
    }

    /// Separates "no such secret for this host" from "secret exists but its value was never entered".
    private static func reportUnresolved(_ unresolved: [String], context: CurlContext, origin: String) throws {
        guard !unresolved.isEmpty else { return }
        for description in unresolved where description.hasPrefix("secret:") {
            let body = description.dropFirst("secret:".count)
            let parts = body.split(separator: ".", maxSplits: 1).map(String.init)
            guard let name = parts.first, let secret = context.secret(named: name, origin: origin) else { continue }
            let missing = secret.kind.fields.filter { context.values.value(secretId: secret.id, field: $0) == nil }
            if !missing.isEmpty {
                throw CurlError.missingSecretValue(secret: name, fields: missing.map(\.rawValue))
            }
        }
        throw CurlError.unresolved(unresolved)
    }
}
