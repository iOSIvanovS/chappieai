// CurlEngineTests.swift
// ChappieCoreTests
//
// Curl-Chappie engine against a stub transport: secret binding, login recipe, session reuse
// between projects, single-flight login, 401 handling, redaction of what the model sees.

import Testing
import Foundation
@testable import ChappieCore

// MARK: - Test doubles

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

private final class StubTransport: CurlTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []
    private let handler: @Sendable (URLRequest) async -> CurlRawResponse

    init(handler: @escaping @Sendable (URLRequest) async -> CurlRawResponse) { self.handler = handler }

    private func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        stored.append(request)
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func requests(path: String) -> [URLRequest] { requests.filter { $0.url?.path == path } }

    func send(_ request: URLRequest) async throws -> CurlRawResponse {
        record(request)
        return await handler(request)
    }
}

private struct MapValues: CurlSecretValueProvider {
    let map: [String: String]
    func value(secretId: UUID, field: CurlSecretField) -> String? { map["\(secretId.uuidString).\(field.rawValue)"] }
}

private let dev = "https://dev.x.ru"
private let prod = "https://prod.x.ru"
private let loginPath = "/api/login/token"

private struct Fixture {
    var context: CurlContext
    var sk: CurlSecret
    var cid: CurlSecret

    init(user: String = "ivan", password: String = "S3cretPass!", secretName: String = "sk",
         permission: CurlHostPermission = .readAndLogin, extraSecrets: [CurlSecret] = [], extraValues: [String: String] = [:]) {
        sk = CurlSecret(name: secretName, kind: .loginPassword, hostOrigin: dev)
        cid = CurlSecret(name: "cid", kind: .plain, hostOrigin: dev)
        var values: [String: String] = [
            "\(sk.id.uuidString).login": user,
            "\(sk.id.uuidString).password": password,
            "\(cid.id.uuidString).value": "client-42"
        ]
        values.merge(extraValues) { $1 }
        context = CurlContext(
            hosts: [
                CurlHost(name: "Dev", origin: dev, permission: permission, loginPath: loginPath),
                CurlHost(name: "Prod", origin: prod, permission: .readOnly)
            ],
            secrets: [sk, cid] + extraSecrets,
            values: MapValues(map: values))
    }

    func recipe(sessionName: String? = nil) -> CurlLoginRecipe {
        CurlLoginRecipe(
            request: CurlRequestSpec(
                method: "POST", url: "\(dev)\(loginPath)",
                body: .form([
                    CurlPair("clientId", "{{secret:cid}}"),
                    CurlPair("login", "{{secret:\(sk.name).login}}"),
                    CurlPair("password", "{{secret:\(sk.name).password}}")
                ]),
                session: sessionName ?? sk.name),
            extract: [
                CurlExtractRule(name: "access_token", source: .json("access_token")),
                CurlExtractRule(name: "token_type", source: .json("token_type"), sensitive: false)
            ],
            apply: [CurlApplyRule(header: "Authorization", template: "{{var:token_type}} {{var:access_token}}")])
    }
}

private func ok(_ json: String, status: Int = 200, cookies: [CurlCookie] = [], headers: [CurlHeader] = []) -> CurlRawResponse {
    CurlRawResponse(status: status, headers: [CurlHeader("Content-Type", "application/json")] + headers,
                    body: Data(json.utf8), cookies: cookies)
}

/// A tiny server: login issues tok-N (N = login count) and a session cookie; any other path echoes the
/// Authorization header it received. `expiring` makes the first token answer 401.
private func server(logins: Counter, expiring: Bool = false, loginDelayMs: UInt64 = 0) -> StubTransport {
    StubTransport { request in
        if request.url?.path == loginPath {
            if loginDelayMs > 0 { try? await Task.sleep(nanoseconds: loginDelayMs * 1_000_000) }
            let n = logins.next()
            return ok(#"{"token_type":"Bearer","access_token":"tok-\#(n)","refresh_token":"refresh-secret-\#(n)","user_id":7}"#,
                      cookies: [CurlCookie(name: "sid", value: "sid-value-\(n)")])
        }
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? "none"
        if expiring && auth == "Bearer tok-1" { return ok(#"{"title":"expired"}"#, status: 401) }
        return ok(#"{"seen_auth":"\#(auth)","refresh_token":"leaky-value-123","ok":true}"#)
    }
}

// MARK: - Tests

@Suite("Curl-Chappie engine")
struct CurlEngineTests {

    private func get(_ path: String, session: String? = "sk") -> CurlRequestSpec {
        CurlRequestSpec(method: "GET", url: "\(dev)\(path)", session: session)
    }

    @Test("Login sends substituted, encoded form data and stores the token without exposing it")
    func loginFlow() async throws {
        let transport = server(logins: Counter())
        let engine = CurlEngine(transport: transport)
        let fx = Fixture()

        let summary = try await engine.login(fx.recipe(), context: fx.context)
        #expect(!summary.reused)
        #expect(summary.generation == 1)
        #expect(summary.storedVariables.contains("access_token (hidden)"))
        #expect(summary.storedVariables.contains("token_type=Bearer"))
        #expect(summary.cookieNames == ["sid"])

        let loginRequest = try #require(transport.requests(path: loginPath).first)
        let body = String(decoding: loginRequest.httpBody ?? Data(), as: UTF8.self)
        #expect(body == "clientId=client-42&login=ivan&password=S3cretPass%21")
        #expect(loginRequest.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(loginRequest.value(forHTTPHeaderField: "Authorization") == nil)

        let rendered = summary.render(sessionLabel: "sk")
        #expect(!rendered.contains("tok-1"))
    }

    @Test("Stored token and cookie are applied automatically and never shown back")
    func tokenApplied() async throws {
        let transport = server(logins: Counter())
        let engine = CurlEngine(transport: transport)
        let fx = Fixture()
        _ = try await engine.login(fx.recipe(), context: fx.context)

        let response = try await engine.send(get("/api/data"), context: fx.context)
        let sent = try #require(transport.requests(path: "/api/data").first)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer tok-1")
        #expect(sent.value(forHTTPHeaderField: "Cookie") == "sid=sid-value-1")

        let text = response.render()
        #expect(!text.contains("tok-1"))
        #expect(!text.contains("sid-value-1"))
        #expect(!text.contains("leaky-value-123"))
        #expect(response.body.contains("<redacted:var:access_token>"))
        #expect(response.body.contains(#""refresh_token":"<redacted>""#))
        #expect(response.body.contains(#""ok":true"#))
    }

    @Test("Second login is a no-op unless forced")
    func loginReuse() async throws {
        let logins = Counter()
        let transport = server(logins: logins)
        let engine = CurlEngine(transport: transport)
        let fx = Fixture()

        _ = try await engine.login(fx.recipe(), context: fx.context)
        let again = try await engine.login(fx.recipe(), context: fx.context)
        #expect(again.reused)
        #expect(transport.requests(path: loginPath).count == 1)

        let forced = try await engine.login(fx.recipe(), context: fx.context, force: true)
        #expect(!forced.reused)
        #expect(forced.generation == 2)
        #expect(transport.requests(path: loginPath).count == 2)
    }

    @Test("Two projects with the same credentials share one session")
    func sharedAcrossProjects() async throws {
        let transport = server(logins: Counter())
        let engine = CurlEngine(transport: transport)
        let projectOne = Fixture(secretName: "sk")
        let projectTwo = Fixture(secretName: "tester")   // other name and ids, identical values

        _ = try await engine.login(projectOne.recipe(), context: projectOne.context)
        _ = try await engine.send(get("/api/data", session: "tester"), context: projectTwo.context)

        #expect(transport.requests(path: loginPath).count == 1)
        let sent = try #require(transport.requests(path: "/api/data").first)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer tok-1")

        let second = try await engine.login(projectTwo.recipe(), context: projectTwo.context)
        #expect(second.reused)
        #expect(transport.requests(path: loginPath).count == 1)
    }

    @Test("Different credentials for the same host never share a session")
    func separateCredentials() async throws {
        let transport = server(logins: Counter())
        let engine = CurlEngine(transport: transport)
        let alice = Fixture(user: "alice", password: "alice-pass-1")
        let bob = Fixture(user: "bob", password: "bob-pass-22")

        _ = try await engine.login(alice.recipe(), context: alice.context)
        let info = try await engine.sessionInfo(origin: dev, session: "sk", context: bob.context)
        #expect(!info.exists)

        _ = try await engine.send(get("/api/data"), context: bob.context)
        let sent = try #require(transport.requests(path: "/api/data").first)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Concurrent logins for one session send a single request")
    func singleFlight() async throws {
        let transport = server(logins: Counter(), loginDelayMs: 150)
        let engine = CurlEngine(transport: transport)
        let fx = Fixture()

        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<5 {
                group.addTask { try await engine.login(fx.recipe(), context: fx.context, force: true).generation }
            }
            var generations = Set<Int>()
            for try await g in group { generations.insert(g) }
            #expect(generations == [1])
        }
        #expect(transport.requests(path: loginPath).count == 1)
    }

    @Test("401 triggers one re-login from the saved recipe and a repeat of the request")
    func reloginOn401() async throws {
        let logins = Counter()
        let transport = server(logins: logins, expiring: true)
        let engine = CurlEngine(transport: transport)
        let fx = Fixture()
        _ = try await engine.login(fx.recipe(), context: fx.context)

        let response = try await engine.send(get("/api/data"), context: fx.context)
        #expect(response.status == 200)
        #expect(response.relogin)
        #expect(transport.requests(path: loginPath).count == 2)
        let last = try #require(transport.requests(path: "/api/data").last)
        #expect(last.value(forHTTPHeaderField: "Authorization") == "Bearer tok-2")
    }

    @Test("A neighbour that already refreshed the session prevents a second login")
    func staleGenerationDoesNotRelogin() async throws {
        let transport = server(logins: Counter())
        let engine = CurlEngine(transport: transport)
        let fx = Fixture()
        let recipe = fx.recipe()
        _ = try await engine.login(recipe, context: fx.context)                 // generation 1
        _ = try await engine.login(recipe, context: fx.context, force: true)    // neighbour: generation 2

        let key = try await engine.sessionKey(name: "sk", origin: dev, context: fx.context)
        let result = try await engine.refreshLogin(key: key, recipe: recipe, context: fx.context, expectedGeneration: 1)
        #expect(result.reused)
        #expect(result.generation == 2)
        #expect(transport.requests(path: loginPath).count == 2)
    }

    @Test("Failed login reports the status and hides secrets in the body")
    func loginFailure() async throws {
        let transport = StubTransport { _ in ok(#"{"title":"bad","echo":"S3cretPass!"}"#, status: 403) }
        let engine = CurlEngine(transport: transport)
        let fx = Fixture()
        do {
            _ = try await engine.login(fx.recipe(), context: fx.context)
            Issue.record("expected failure")
        } catch let error as CurlError {
            guard case .loginFailed(let message) = error else { Issue.record("wrong error \(error)"); return }
            #expect(message.contains("403"))
            #expect(!message.contains("S3cretPass!"))
        }
    }

    @Test("Missing token in the login response names the missing values")
    func loginMissingValue() async throws {
        let transport = StubTransport { _ in ok(#"{"token_type":"Bearer"}"#) }
        let engine = CurlEngine(transport: transport)
        let fx = Fixture()
        do {
            _ = try await engine.login(fx.recipe(), context: fx.context)
            Issue.record("expected failure")
        } catch let error as CurlError {
            guard case .loginFailed(let message) = error else { Issue.record("wrong error \(error)"); return }
            #expect(message.contains("access_token"))
        }
    }

    // MARK: - Binding and gate

    @Test("A secret bound to another host is never substituted")
    func secretBinding() async throws {
        let prodKey = CurlSecret(name: "apikey", kind: .token, hostOrigin: prod)
        let fx = Fixture(extraSecrets: [prodKey], extraValues: ["\(prodKey.id.uuidString).value": "prod-key-9999"])
        let transport = StubTransport { _ in ok("{}") }
        let engine = CurlEngine(transport: transport)

        let toDev = CurlRequestSpec(method: "GET", url: "\(dev)/x", headers: [CurlHeader("X-Key", "{{secret:apikey}}")])
        do {
            _ = try await engine.send(toDev, context: fx.context)
            Issue.record("expected unresolved")
        } catch let error as CurlError {
            #expect(error == .unresolved(["secret:apikey"]))
        }
        #expect(transport.requests.isEmpty)

        let toProd = CurlRequestSpec(method: "GET", url: "\(prod)/x", headers: [CurlHeader("X-Key", "{{secret:apikey}}")])
        _ = try await engine.send(toProd, context: fx.context)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "X-Key") == "prod-key-9999")
    }

    @Test("A secret without a stored value reports what to enter")
    func missingValue() async throws {
        let orphan = CurlSecret(name: "empty", kind: .loginPassword, hostOrigin: dev)
        let fx = Fixture(extraSecrets: [orphan])
        let engine = CurlEngine(transport: StubTransport { _ in ok("{}") })
        let spec = CurlRequestSpec(method: "GET", url: "\(dev)/x", headers: [CurlHeader("X", "{{secret:empty.password}}")])
        do {
            _ = try await engine.send(spec, context: fx.context)
            Issue.record("expected failure")
        } catch let error as CurlError {
            #expect(error == .missingSecretValue(secret: "empty", fields: ["login", "password"]))
        }
    }

    @Test("Write methods follow the host permission")
    func permissions() async throws {
        let engine = CurlEngine(transport: StubTransport { _ in ok("{}") })
        let fx = Fixture()
        for url in ["\(dev)/api/items", "\(prod)/api/items"] {
            do {
                _ = try await engine.send(CurlRequestSpec(method: "DELETE", url: url), context: fx.context)
                Issue.record("expected denial for \(url)")
            } catch let error as CurlError {
                guard case .denied = error else { Issue.record("wrong error \(error)"); return }
            }
        }
        let full = Fixture(permission: .full)
        _ = try await engine.send(CurlRequestSpec(method: "DELETE", url: "\(dev)/api/items/1"), context: full.context)
    }

    @Test("Placeholders in scheme or host are refused")
    func hostPlaceholder() async throws {
        let engine = CurlEngine(transport: StubTransport { _ in ok("{}") })
        let fx = Fixture()
        for url in ["https://{{var:h}}/x", "https://dev.x.ru{{var:p}}@evil.example/x", "{{var:s}}://dev.x.ru/x"] {
            do {
                _ = try await engine.send(CurlRequestSpec(method: "GET", url: url), context: fx.context)
                Issue.record("expected refusal for \(url)")
            } catch is CurlError {}
        }
    }

    @Test("A substituted value cannot move the request to another host")
    func substitutionCannotChangeHost() async throws {
        let evil = CurlSecret(name: "path", kind: .plain, hostOrigin: dev)
        let fx = Fixture(extraSecrets: [evil], extraValues: ["\(evil.id.uuidString).value": "@evil.example/steal"])
        // URL components are percent-encoded, so "@" and "/" cannot restructure the URL.
        let spec = CurlRequestSpec(method: "GET", url: "\(dev)/{{secret:path}}")
        let transport = StubTransport { _ in ok("{}") }
        let engine = CurlEngine(transport: transport)
        _ = try await engine.send(spec, context: fx.context)
        #expect(transport.requests.first?.url?.host == "dev.x.ru")
        #expect(transport.requests.first?.url?.absoluteString == "\(dev)/%40evil.example%2Fsteal")
    }

    @Test("Header values cannot carry line breaks")
    func headerInjection() async throws {
        let engine = CurlEngine(transport: StubTransport { _ in ok("{}") })
        let fx = Fixture()
        let spec = CurlRequestSpec(method: "GET", url: "\(dev)/x", headers: [CurlHeader("X-A", "a\r\nX-B: injected")])
        do {
            _ = try await engine.send(spec, context: fx.context)
            Issue.record("expected refusal")
        } catch let error as CurlError {
            guard case .invalidRequest = error else { Issue.record("wrong error \(error)"); return }
        }
        for forbidden in ["Cookie", "Host", "Content-Length"] {
            let bad = CurlRequestSpec(method: "GET", url: "\(dev)/x", headers: [CurlHeader(forbidden, "x")])
            await #expect(throws: CurlError.self) { _ = try await engine.send(bad, context: fx.context) }
        }
    }

    // MARK: - Responses

    @Test("Query pairs are encoded and merged with the URL query")
    func queryMerge() async throws {
        let transport = StubTransport { _ in ok("{}") }
        let engine = CurlEngine(transport: transport)
        let fx = Fixture()
        let spec = CurlRequestSpec(method: "GET", url: "\(dev)/s?a=1", query: [CurlPair("q", "x y&z")])
        _ = try await engine.send(spec, context: fx.context)
        #expect(transport.requests.first?.url?.absoluteString == "\(dev)/s?a=1&q=x%20y%26z")
    }

    @Test("JSON body substitution is escaped")
    func jsonBody() async throws {
        let quote = CurlSecret(name: "note", kind: .plain, hostOrigin: dev)
        let fx = Fixture(permission: .full, extraSecrets: [quote], extraValues: ["\(quote.id.uuidString).value": "say \"hi\"\nnow"])
        let transport = StubTransport { _ in ok("{}") }
        let engine = CurlEngine(transport: transport)
        let spec = CurlRequestSpec(method: "POST", url: "\(dev)/notes", body: .json(#"{"text":"{{secret:note}}"}"#))
        _ = try await engine.send(spec, context: fx.context)
        let body = try #require(transport.requests.first?.httpBody)
        let parsed = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(parsed?["text"] == "say \"hi\"\nnow")
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("Redirects are reported, not followed")
    func redirectNote() async throws {
        let engine = CurlEngine(transport: StubTransport { _ in
            CurlRawResponse(status: 302, headers: [CurlHeader("Location", "https://other.example/x")])
        })
        let response = try await engine.send(CurlRequestSpec(method: "GET", url: "\(dev)/r"), context: Fixture().context)
        #expect(response.status == 302)
        #expect(response.notes.contains { $0.contains("not followed") && $0.contains("other.example") })
    }

    @Test("Binary bodies are summarised")
    func binaryBody() async throws {
        let engine = CurlEngine(transport: StubTransport { _ in
            CurlRawResponse(status: 200, headers: [CurlHeader("Content-Type", "application/pdf")], body: Data(repeating: 0xFF, count: 10))
        })
        let response = try await engine.send(CurlRequestSpec(method: "GET", url: "\(dev)/f"), context: Fixture().context)
        #expect(response.body.contains("binary body omitted"))
    }

    @Test("Request rate is limited per minute")
    func rateLimit() async throws {
        let engine = CurlEngine(transport: StubTransport { _ in ok("{}") }, rateLimit: 3)
        let fx = Fixture()
        for _ in 0..<3 { _ = try await engine.send(CurlRequestSpec(method: "GET", url: "\(dev)/x"), context: fx.context) }
        await #expect(throws: CurlError.rateLimited(limit: 3)) {
            _ = try await engine.send(CurlRequestSpec(method: "GET", url: "\(dev)/x"), context: fx.context)
        }
    }

    // MARK: - Extract and reset

    @Test("curl_extract keeps sensitive values hidden and makes them usable as variables")
    func extractFlow() async throws {
        let transport = StubTransport { request in
            request.url?.path == "/csrf" ? ok(#"{"csrf":"csrf-value-77","public":"hello"}"#) : ok("{}")
        }
        let engine = CurlEngine(transport: transport)
        let fx = Fixture()
        _ = try await engine.send(get("/csrf", session: nil), context: fx.context)

        let hidden = try await engine.extract(CurlExtractRule(name: "csrf", source: .json("csrf")),
                                              origin: "Dev", session: nil, context: fx.context)
        #expect(hidden.shownValue == nil)
        let shown = try await engine.extract(CurlExtractRule(name: "pub", source: .json("public"), sensitive: false),
                                             origin: dev, session: nil, context: fx.context)
        #expect(shown.shownValue == "hello")

        _ = try await engine.send(CurlRequestSpec(method: "GET", url: "\(dev)/use", headers: [CurlHeader("X-Csrf", "{{var:csrf}}")]),
                                  context: fx.context)
        #expect(transport.requests(path: "/use").first?.value(forHTTPHeaderField: "X-Csrf") == "csrf-value-77")

        let info = try await engine.sessionInfo(origin: dev, session: nil, context: fx.context)
        #expect(info.variables == ["csrf": true, "pub": false])
    }

    @Test("Reset drops the session")
    func reset() async throws {
        let engine = CurlEngine(transport: server(logins: Counter()))
        let fx = Fixture()
        _ = try await engine.login(fx.recipe(), context: fx.context)
        #expect(try await engine.resetSession(origin: dev, session: "sk", context: fx.context))
        let info = try await engine.sessionInfo(origin: dev, session: "sk", context: fx.context)
        #expect(!info.exists)
    }

    @Test("Host names resolve to listed origins only")
    func resolveOrigin() {
        let engine = CurlEngine(transport: StubTransport { _ in ok("{}") })
        let fx = Fixture()
        #expect(engine.resolveOrigin("dev", context: fx.context) == dev)
        #expect(engine.resolveOrigin("HTTPS://DEV.x.ru/path", context: fx.context) == dev)
        #expect(engine.resolveOrigin("https://nope.example", context: fx.context) == nil)
    }
}
