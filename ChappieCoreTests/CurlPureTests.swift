// CurlPureTests.swift
// ChappieCoreTests
//
// Curl-Chappie pure parts: allow-list gate, placeholder substitution, response redaction,
// JSON extraction and the cookie jar. No network, no Keychain.

import Testing
import Foundation
@testable import ChappieCore

@Suite("Curl-Chappie gate")
struct CurlGateTests {

    private let readOnly = CurlHost(name: "RO", origin: "https://ro.x.ru", permission: .readOnly)
    private let login = CurlHost(name: "Login", origin: "https://dev.x.ru", permission: .readAndLogin, loginPath: "/api/login/token")
    private let full = CurlHost(name: "Full", origin: "https://full.x.ru:8443", permission: .full)

    private var hosts: [CurlHost] { [readOnly, login, full] }

    private func eval(_ method: String, _ url: String) -> CurlAccess {
        CurlGate.evaluate(method: method, url: URL(string: url)!, hosts: hosts)
    }

    private func isAllowed(_ access: CurlAccess) -> Bool {
        if case .allowed = access { return true }
        return false
    }

    @Test("Reads are allowed on every listed host")
    func readsAllowed() {
        #expect(isAllowed(eval("GET", "https://ro.x.ru/a?b=1")))
        #expect(isAllowed(eval("head", "https://dev.x.ru/anything")))
        #expect(isAllowed(eval("GET", "https://full.x.ru:8443/")))
    }

    @Test("Host matching ignores case and default port")
    func hostMatching() {
        #expect(isAllowed(eval("GET", "HTTPS://RO.X.RU:443/p")))
        #expect(!isAllowed(eval("GET", "https://full.x.ru/p")))   // other port
    }

    @Test("Unlisted host and empty list are denied with an actionable message")
    func unlisted() {
        guard case .denied(let message) = eval("GET", "https://evil.example/") else { Issue.record("expected denial"); return }
        #expect(message.contains("not in this thread's Curl-Chappie host list"))
        guard case .denied(let empty) = CurlGate.evaluate(method: "GET", url: URL(string: "https://a.b")!, hosts: []) else { Issue.record("expected denial"); return }
        #expect(empty.contains("no Curl-Chappie hosts"))
    }

    @Test("Read-only host refuses every write method")
    func readOnlyRefusesWrites() {
        for method in ["POST", "PUT", "PATCH", "DELETE"] {
            #expect(!isAllowed(eval(method, "https://ro.x.ru/api/login/token")))
        }
    }

    @Test("Read+login host allows POST only to the exact login path")
    func readAndLogin() {
        guard case .allowed(_, let isLogin) = eval("POST", "https://dev.x.ru/api/login/token") else { Issue.record("expected allowed"); return }
        #expect(isLogin)
        #expect(isAllowed(eval("POST", "https://dev.x.ru/api/login/token/?x=1")))
        #expect(!isAllowed(eval("POST", "https://dev.x.ru/api/other")))
        #expect(!isAllowed(eval("DELETE", "https://dev.x.ru/api/login/token")))
        #expect(!isAllowed(eval("PUT", "https://dev.x.ru/api/login/token")))
    }

    @Test("Dot segments and encoded dots cannot pass as the login path")
    func dotSegments() {
        #expect(!isAllowed(eval("POST", "https://dev.x.ru/api/login/token/../../admin")))
        #expect(!isAllowed(eval("POST", "https://dev.x.ru/api/login/token/%2e%2e/admin")))
        #expect(!isAllowed(eval("POST", "https://dev.x.ru/api/login/token/./")))
    }

    @Test("Read+login host without a login path refuses all POST")
    func noLoginPath() {
        let host = CurlHost(name: "X", origin: "https://nolp.x.ru", permission: .readAndLogin)
        let access = CurlGate.evaluate(method: "POST", url: URL(string: "https://nolp.x.ru/")!, hosts: [host])
        #expect(!isAllowed(access))
    }

    @Test("Full host allows writes and flags the login path")
    func fullAccess() {
        #expect(isAllowed(eval("DELETE", "https://full.x.ru:8443/items/1")))
        #expect(isAllowed(eval("PATCH", "https://full.x.ru:8443/items/1")))
    }

    @Test("Unknown method and unsupported scheme are denied")
    func oddInput() {
        #expect(!isAllowed(eval("TRACE", "https://ro.x.ru/")))
        #expect(!isAllowed(CurlGate.evaluate(method: "GET", url: URL(string: "ftp://ro.x.ru/")!, hosts: hosts)))
    }

    @Test("isMutating")
    func mutating() {
        #expect(!CurlGate.isMutating("get"))
        #expect(!CurlGate.isMutating("HEAD"))
        #expect(CurlGate.isMutating("post"))
        #expect(CurlGate.isMutating("DELETE"))
    }
}

@Suite("Curl-Chappie templates")
struct CurlTemplateTests {

    @Test("References are found with and without field")
    func references() {
        let refs = CurlTemplate.references(in: "a {{secret:sk.login}} b {{ var:token }} c {{secret:cid}} {{nope:x}}")
        #expect(refs.map(\.description) == ["secret:sk.login", "var:token", "secret:cid"])
    }

    @Test("Names with spaces and non-Latin letters parse; the field stays after the dot")
    func unicodeNames() {
        let refs = CurlTemplate.references(in: "{{secret:Юлин логин.password}} {{ secret:Логин Олега }} {{var:id}}")
        #expect(refs.map(\.name) == ["Юлин логин", "Логин Олега", "id"])
        #expect(refs.map(\.field) == ["password", nil, nil])
        #expect(CurlTemplate.neutralized("https://h.x/{{var:id}}/{{secret:Мой логин.login}}") == "https://h.x/_/_")
    }

    @Test("Substitution encodes for the destination")
    func encoding() {
        let resolver: (CurlReference) -> String? = { _ in "a b&\"c\"\n" }
        #expect(CurlTemplate.substitute("x={{secret:s}}", mode: .raw, resolver: resolver).text == "x=a b&\"c\"\n")
        #expect(CurlTemplate.substitute("x={{secret:s}}", mode: .urlComponent, resolver: resolver).text == "x=a%20b%26%22c%22%0A")
        #expect(CurlTemplate.substitute("{\"k\":\"{{secret:s}}\"}", mode: .jsonString, resolver: resolver).text == "{\"k\":\"a b&\\\"c\\\"\\n\"}")
    }

    @Test("Substitution is single pass: a value that looks like a reference is not expanded")
    func singlePass() {
        let resolver: (CurlReference) -> String? = { ref in
            ref.name == "a" ? "{{secret:b}}" : "TOP-SECRET"
        }
        let result = CurlTemplate.substitute("{{secret:a}}", mode: .raw, resolver: resolver)
        #expect(result.text == "{{secret:b}}")
        #expect(!result.text.contains("TOP-SECRET"))
    }

    @Test("Unresolved references stay in the text and are reported in order")
    func unresolved() {
        let result = CurlTemplate.substitute("{{secret:x.login}}/{{var:y}}", mode: .raw) { _ in nil }
        #expect(result.text == "{{secret:x.login}}/{{var:y}}")
        #expect(result.unresolved == ["secret:x.login", "var:y"])
    }

    @Test("Neutralized form lets a URL be parsed before substitution")
    func neutralized() {
        #expect(CurlTemplate.neutralized("https://h.x/p/{{var:id}}?q={{secret:k}}") == "https://h.x/p/_?q=_")
    }
}

@Suite("Curl-Chappie redaction")
struct CurlRedactorTests {

    @Test("Known values are removed in plain, JSON-escaped and percent-encoded form")
    func knownValues() {
        let redactor = CurlRedactor(entries: [("secret:sk.password", "p\"w d1234")])
        let text = #"plain p"w d1234 json p\"w d1234 url p%22w%20d1234"#
        let out = redactor.redact(text)
        #expect(!out.contains("d1234"))
        #expect(out.components(separatedBy: "<redacted:secret:sk.password>").count == 4)
    }

    @Test("Values shorter than the minimum are left alone")
    func shortValues() {
        let redactor = CurlRedactor(entries: [("secret:a", "ab")])
        #expect(redactor.redact("abab") == "abab")
    }

    @Test("A longer value containing a shorter one is replaced whole")
    func longestFirst() {
        let redactor = CurlRedactor(entries: [("short", "tokn"), ("long", "tokn-and-more")])
        let out = redactor.redact("x tokn-and-more y")
        #expect(out == "x <redacted:long> y")
    }

    @Test("Credential-looking JSON keys are masked, token_type is kept")
    func jsonKeys() {
        let redactor = CurlRedactor(entries: [])
        let body = #"{"token_type":"Bearer","access_token":"abc","refresh_token":"def","user":{"password":"x","name":"Ivan"},"n":5}"#
        let out = redactor.redactBody(body)
        #expect(out.contains(#""token_type":"Bearer""#))
        #expect(out.contains(#""access_token":"<redacted>""#))
        #expect(out.contains(#""refresh_token":"<redacted>""#))
        #expect(out.contains(#""password":"<redacted>""#))
        #expect(out.contains(#""name":"Ivan""#))
    }

    @Test("Non-JSON bodies are not key-masked")
    func plainBody() {
        let redactor = CurlRedactor(entries: [])
        let text = #"the "token": "visible" in prose"#
        #expect(redactor.redactBody(text) == text)
    }

    @Test("Credential headers are masked, Set-Cookie is dropped, others pass")
    func headers() {
        let redactor = CurlRedactor(entries: [("secret:k", "key-value-1")])
        let out = redactor.redactHeaders([
            CurlHeader("Authorization", "Bearer abc"),
            CurlHeader("Set-Cookie", "sid=1"),
            CurlHeader("X-Api-Key", "zzz"),
            CurlHeader("X-Echo", "got key-value-1"),
            CurlHeader("Content-Type", "application/json")
        ])
        #expect(out.map(\.name) == ["Authorization", "X-Api-Key", "X-Echo", "Content-Type"])
        #expect(out[0].value == "<redacted>")
        #expect(out[1].value == "<redacted>")
        #expect(out[2].value == "got <redacted:secret:k>")
        #expect(out[3].value == "application/json")
    }
}

@Suite("Curl-Chappie JSON path and cookies")
struct CurlPathAndCookieTests {

    private func extract(_ path: String, _ json: String) -> String? {
        CurlJSONPath.extract(path, from: Data(json.utf8))
    }

    @Test("Paths into objects and arrays")
    func paths() {
        let json = #"{"access_token":"T","data":{"items":[{"id":1},{"id":2,"ok":true}],"nil":null},"n":1.5}"#
        #expect(extract("access_token", json) == "T")
        #expect(extract("$.access_token", json) == "T")
        #expect(extract("data.items[1].id", json) == "2")
        #expect(extract("data.items[1].ok", json) == "true")
        #expect(extract("n", json) == "1.5")
        #expect(extract("data.items[0]", json) == #"{"id":1}"#)
    }

    @Test("Missing, null and malformed paths return nil")
    func misses() {
        let json = #"{"a":{"b":null},"l":[1]}"#
        #expect(extract("a.b", json) == nil)
        #expect(extract("a.c", json) == nil)
        #expect(extract("l[5]", json) == nil)
        #expect(extract("a..b", json) == nil)
        #expect(extract("", json) == nil)
        #expect(extract("l[x]", json) == nil)
        #expect(extract("a", "not json") == nil)
    }

    @Test("Top-level array index")
    func topLevelArray() {
        #expect(extract("[0].id", #"[{"id":9}]"#) == "9")
    }

    @Test("Cookie jar merge, deletion by expiry and header building")
    func jar() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var jar = CurlCookieJar.merge([], [CurlCookie(name: "sid", value: "1"), CurlCookie(name: "a", value: "x", path: "/api")], now: now)
        #expect(CurlCookieJar.header(jar, path: "/api/v1", isHTTPS: true, now: now) == "a=x; sid=1")
        #expect(CurlCookieJar.header(jar, path: "/other", isHTTPS: true, now: now) == "sid=1")

        jar = CurlCookieJar.merge(jar, [CurlCookie(name: "sid", value: "2")], now: now)
        #expect(CurlCookieJar.header(jar, path: "/x", isHTTPS: true, now: now) == "sid=2")

        jar = CurlCookieJar.merge(jar, [CurlCookie(name: "sid", value: "", expires: now.addingTimeInterval(-10))], now: now)
        #expect(CurlCookieJar.header(jar, path: "/x", isHTTPS: true, now: now) == nil)
    }

    @Test("Secure cookies are not sent over http")
    func secureCookie() {
        let now = Date()
        let jar = [CurlCookie(name: "s", value: "1", secure: true)]
        #expect(CurlCookieJar.header(jar, path: "/", isHTTPS: false, now: now) == nil)
        #expect(CurlCookieJar.header(jar, path: "/", isHTTPS: true, now: now) == "s=1")
    }

    @Test("Session fingerprint depends on values, not on order")
    func fingerprint() {
        let a = CurlSessionKey.fingerprint(of: [("login", "u"), ("password", "p")])
        let b = CurlSessionKey.fingerprint(of: [("password", "p"), ("login", "u")])
        let c = CurlSessionKey.fingerprint(of: [("login", "u"), ("password", "q")])
        #expect(a == b)
        #expect(a != c)
        #expect(a.count == 24)
    }
}
