// CurlModelsTests.swift
// ChappieCoreTests
//
// Curl-Chappie data model: origin normalization, backward-compatible decoding of old
// stored JSON, secret naming rules and Keychain round trips.
//
// Keychain tests use a unique service per test and clean up, so they never touch real items.

import Testing
import Foundation
@testable import ChappieCore

@Suite("Curl-Chappie models")
struct CurlModelsTests {

    // MARK: - Origin normalization

    @Test("Origin: scheme and host lowercased, default port and path dropped")
    func originNormalizes() {
        #expect(CurlOrigin.normalize("HTTPS://Dev.Adept.ru:443/api/x?y=1") == "https://dev.adept.ru")
        #expect(CurlOrigin.normalize("http://host:80") == "http://host")
        #expect(CurlOrigin.normalize("https://host:8443/") == "https://host:8443")
        #expect(CurlOrigin.normalize("  https://a.b  ") == "https://a.b")
    }

    @Test("Origin: rejects non-http schemes, missing host and embedded credentials")
    func originRejects() {
        #expect(CurlOrigin.normalize("ftp://host") == nil)
        #expect(CurlOrigin.normalize("file:///etc/passwd") == nil)
        #expect(CurlOrigin.normalize("") == nil)
        #expect(CurlOrigin.normalize("dev.adept.ru") == nil)
        #expect(CurlOrigin.normalize("https://user:pw@host") == nil)
    }

    @Test("Login path normalization")
    func loginPath() {
        #expect(CurlOrigin.normalizePath("api/login/token") == "/api/login/token")
        #expect(CurlOrigin.normalizePath("/api/login/?x=1") == "/api/login")
        #expect(CurlOrigin.normalizePath("") == "")
        #expect(CurlOrigin.normalizePath("/") == "/")
    }

    @Test("Host init normalizes origin and path")
    func hostInit() {
        let h = CurlHost(name: "Dev", origin: "HTTPS://DEV.adept.ru/", permission: .readAndLogin, loginPath: "api/login")
        #expect(h.origin == "https://dev.adept.ru")
        #expect(h.loginPath == "/api/login")
    }

    // MARK: - Codable compatibility

    @Test("Old ThreadSettings JSON without curl keys decodes with defaults and keeps old values")
    func oldThreadSettingsDecode() throws {
        let oldJSON = #"{"maxMessagesInContext":120,"isUnlimitedContext":true,"terminalAccess":"auto","activeModelName":"m"}"#
        let s = try JSONDecoder().decode(ThreadSettings.self, from: Data(oldJSON.utf8))
        #expect(s.maxMessagesInContext == 120)
        #expect(s.isUnlimitedContext)
        #expect(s.terminalAccess == .auto)
        #expect(s.activeModelName == "m")
        #expect(s.curlEnabled == false)
        #expect(s.curlHosts.isEmpty)
    }

    @Test("ThreadSettings round trip keeps hosts")
    func threadSettingsRoundTrip() throws {
        var s = ThreadSettings()
        s.curlEnabled = true
        s.curlHosts = [CurlHost(name: "Dev", origin: "https://dev.x.ru", permission: .full)]
        let back = try JSONDecoder().decode(ThreadSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test("Old ProjectSettings JSON decodes with empty secrets")
    func oldProjectSettingsDecode() throws {
        let old = #"{"agentRole":"executor","terminalAccess":"confirm"}"#
        let s = try JSONDecoder().decode(ProjectSettings.self, from: Data(old.utf8))
        #expect(s.agentRole == .executor)
        #expect(s.curlSecrets.isEmpty)
    }

    @Test("Unknown host permission falls back to the safest level")
    func unknownPermission() throws {
        let json = #"{"name":"X","origin":"https://x.y","permission":"godMode"}"#
        let h = try JSONDecoder().decode(CurlHost.self, from: Data(json.utf8))
        #expect(h.permission == .readOnly)
    }

    @Test("ProjectSettings round trip keeps secret metadata but no values")
    func projectSettingsRoundTrip() throws {
        var p = ProjectSettings(agentRole: .executor)
        p.curlSecrets = [CurlSecret(name: "sk_test", kind: .loginPassword, hostOrigin: "https://dev.x.ru")]
        let data = try JSONEncoder().encode(p)
        #expect(try JSONDecoder().decode(ProjectSettings.self, from: data) == p)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("password\":\""))
    }

    // MARK: - Secret rules

    @Test("Secret names use a tiny alphabet")
    func secretNames() {
        #expect(CurlSecret.isValidName("sk_test-1"))
        #expect(!CurlSecret.isValidName(""))
        #expect(!CurlSecret.isValidName("a b"))
        #expect(!CurlSecret.isValidName("a.b"))
        #expect(!CurlSecret.isValidName("a}}"))
        #expect(!CurlSecret.isValidName(String(repeating: "a", count: 65)))
    }

    @Test("Same name on different hosts is allowed, same name on the same host is a duplicate")
    func duplicates() {
        let a = CurlSecret(name: "login", kind: .loginPassword, hostOrigin: "https://dev.x.ru")
        let b = CurlSecret(name: "login", kind: .loginPassword, hostOrigin: "https://prod.x.ru")
        let c = CurlSecret(name: "login", kind: .token, hostOrigin: "https://DEV.x.ru/")
        #expect(!CurlSecret.hasDuplicate(of: b, in: [a, b]))
        #expect(CurlSecret.hasDuplicate(of: c, in: [a]))
    }

    @Test("Kinds expose the right value fields")
    func kindFields() {
        #expect(CurlSecretKind.loginPassword.fields == [.login, .password])
        #expect(CurlSecretKind.token.fields == [.value])
    }

    // MARK: - Keychain

    private func makeKeychain() -> CurlSecretKeychain {
        CurlSecretKeychain(service: "ru.chappie.tests.curl.\(UUID().uuidString)")
    }

    @Test("Keychain round trip, overwrite and delete")
    func keychainRoundTrip() {
        let kc = makeKeychain()
        let id = UUID()
        defer { kc.delete(secretId: id) }

        #expect(kc.load(secretId: id, field: .password) == nil)
        #expect(kc.save("p1", secretId: id, field: .password))
        #expect(kc.load(secretId: id, field: .password) == "p1")
        #expect(kc.save("p2", secretId: id, field: .password))
        #expect(kc.load(secretId: id, field: .password) == "p2")
        kc.delete(secretId: id)
        #expect(kc.load(secretId: id, field: .password) == nil)
    }

    @Test("Empty value removes the item")
    func keychainEmptyDeletes() {
        let kc = makeKeychain()
        let id = UUID()
        defer { kc.delete(secretId: id) }
        kc.save("x", secretId: id, field: .value)
        kc.save("", secretId: id, field: .value)
        #expect(kc.load(secretId: id, field: .value) == nil)
    }

    @Test("missingFields reports parts without a stored value")
    func keychainMissing() {
        let kc = makeKeychain()
        let secret = CurlSecret(name: "s", kind: .loginPassword, hostOrigin: "https://h.x")
        defer { kc.delete(secretId: secret.id) }

        #expect(kc.missingFields(of: secret) == [.login, .password])
        kc.save("u", secretId: secret.id, field: .login)
        #expect(kc.missingFields(of: secret) == [.password])
        kc.save("p", secretId: secret.id, field: .password)
        #expect(kc.missingFields(of: secret).isEmpty)
    }

    @Test("delete(secretId:) removes all parts")
    func keychainDeleteAllParts() {
        let kc = makeKeychain()
        let id = UUID()
        kc.save("u", secretId: id, field: .login)
        kc.save("p", secretId: id, field: .password)
        kc.delete(secretId: id)
        #expect(kc.load(secretId: id, field: .login) == nil)
        #expect(kc.load(secretId: id, field: .password) == nil)
    }
}
