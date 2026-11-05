// CurlValidationTests.swift
// Rules behind the Curl-Chappie settings tables.

import Testing
import Foundation
@testable import ChappieCore

struct CurlValidationTests {

    private func host(_ name: String = "Dev", _ origin: String = "https://dev.x.ru",
                      _ permission: CurlHostPermission = .full, login: String = "") -> CurlHost {
        CurlHost(name: name, origin: origin, permission: permission, loginPath: login)
    }

    @Test func validHostHasNoIssue() {
        let h = host()
        #expect(CurlValidation.issue(for: h, in: [h]) == nil)
    }

    @Test func emptyNameAndBadOriginAreReported() {
        var h = host(" ")
        #expect(CurlValidation.issue(for: h, in: [h]) == .emptyName)
        h = host("Dev", "ftp://x")
        #expect(CurlValidation.issue(for: h, in: [h]) == .invalidOrigin)
        h = host("Dev", "https://u:p@x.ru")
        #expect(CurlValidation.issue(for: h, in: [h]) == .invalidOrigin)
    }

    @Test func duplicateOriginIsCaughtAfterNormalization() {
        let a = host("A", "https://dev.x.ru")
        var b = host("B", "x")
        b.origin = "HTTPS://Dev.X.ru:443/api"   // edited in a text field, not yet normalized
        #expect(CurlValidation.issue(for: b, in: [a, b]) == .duplicateOrigin)
    }

    @Test func readAndLoginNeedsAPath() {
        let h = host("Dev", "https://dev.x.ru", .readAndLogin, login: "")
        #expect(CurlValidation.issue(for: h, in: [h]) == .missingLoginPath)
        let ok = host("Dev", "https://dev.x.ru", .readAndLogin, login: "api/login")
        #expect(CurlValidation.issue(for: ok, in: [ok]) == nil)
    }

    @Test func secretRules() {
        let host = "https://dev.x.ru"
        let ok = CurlSecret(name: "Юлин логин", kind: .loginPassword, hostOrigin: host)
        #expect(CurlValidation.issue(for: ok, in: [ok]) == nil)

        let bad = CurlSecret(name: "a.b", kind: .plain, hostOrigin: host)
        #expect(CurlValidation.issue(for: bad, in: [bad]) == .invalidName)

        let noHost = CurlSecret(name: "x", kind: .plain, hostOrigin: "")
        #expect(CurlValidation.issue(for: noHost, in: [noHost]) == .missingHost)

        let dup = CurlSecret(name: "Юлин логин", kind: .token, hostOrigin: host)
        #expect(CurlValidation.issue(for: dup, in: [ok, dup]) == .duplicate)

        // Same name on another host is allowed — that is the dev/prod use case.
        let other = CurlSecret(name: "Юлин логин", kind: .loginPassword, hostOrigin: "https://prod.x.ru")
        #expect(CurlValidation.issue(for: other, in: [ok, other]) == nil)
    }

    @Test func customHeaderNeedsAHeaderName() {
        var s = CurlSecret(name: "key", kind: .customHeader, hostOrigin: "https://dev.x.ru")
        #expect(CurlValidation.issue(for: s, in: [s]) == .missingHeaderName)
        s.headerName = "X-Api-Key"
        #expect(CurlValidation.issue(for: s, in: [s]) == nil)
    }

    // MARK: - Keychain commit from the project sheet

    @Test func applyWritesKeepsAndRemoves() {
        let kc = CurlSecretKeychain(service: "ru.chappie.tests.curl.apply.\(UUID().uuidString)")
        var login = CurlSecret(name: "Oleg", kind: .loginPassword, hostOrigin: "https://dev.x.ru")
        let gone = CurlSecret(name: "Old", kind: .token, hostOrigin: "https://dev.x.ru")
        defer { kc.deleteAll([login, gone]) }

        kc.save("old-token", secretId: gone.id, field: .value)
        #expect(kc.apply(secrets: [login], typed: [login.id: [.login: "oleg", .password: "p1"]], removed: [gone]))
        #expect(kc.load(secretId: login.id, field: .login) == "oleg")
        #expect(kc.load(secretId: login.id, field: .password) == "p1")
        #expect(kc.load(secretId: gone.id, field: .value) == nil)
        #expect(kc.savedFields(of: [login]).count == 2)

        // Empty typed value = "keep what is stored" (the UI never shows stored values).
        kc.apply(secrets: [login], typed: [login.id: [.password: ""]], removed: [])
        #expect(kc.load(secretId: login.id, field: .password) == "p1")

        // Switching to a token drops the leftover login/password parts.
        login.kind = .token
        kc.apply(secrets: [login], typed: [login.id: [.value: "tok"]], removed: [])
        #expect(kc.load(secretId: login.id, field: .value) == "tok")
        #expect(kc.load(secretId: login.id, field: .login) == nil)
        #expect(kc.load(secretId: login.id, field: .password) == nil)
    }

    @Test func saveGateIgnoresBlankRowsAndDisabledTool() {
        var t = ThreadSettings()
        t.curlHosts = [CurlHost(name: "", origin: ""), CurlHost(name: "Bad", origin: "ftp://x")]
        t.curlEnabled = false
        #expect(t.curlHostsAreSaveable)          // tool off never blocks unrelated settings
        t.curlEnabled = true
        #expect(!t.curlHostsAreSaveable)         // the filled-in invalid row blocks
        t.curlHosts = [CurlHost(name: "", origin: "")]
        #expect(t.curlHostsAreSaveable)          // a blank row is just dropped
        #expect(CurlValidation.droppingBlank(t.curlHosts).isEmpty)

        var p = ProjectSettings(agentRole: .executor)
        p.curlSecrets = [CurlSecret(name: "", kind: .plain, hostOrigin: "")]
        #expect(p.curlSecretsAreSaveable)
        p.curlSecrets = [CurlSecret(name: "a.b", kind: .plain, hostOrigin: "https://x.ru")]
        #expect(!p.curlSecretsAreSaveable)
    }

    @Test func normalizationCleansWhatIsStored() {
        var h = host("  Dev ", "x", .readOnly, login: "/old")
        h.origin = "HTTPS://Dev.X.ru:443/api?x=1"
        let n = CurlValidation.normalized([h])[0]
        #expect(n.name == "Dev")
        #expect(n.origin == "https://dev.x.ru")
        #expect(n.loginPath.isEmpty)   // not relevant for readOnly

        var s = CurlSecret(name: "k", kind: .token, hostOrigin: "x")
        s.hostOrigin = "HTTPS://Dev.X.ru/"
        s.headerName = "X-Stale"
        let ns = CurlValidation.normalized([s])[0]
        #expect(ns.hostOrigin == "https://dev.x.ru")
        #expect(ns.headerName.isEmpty)
    }
}
