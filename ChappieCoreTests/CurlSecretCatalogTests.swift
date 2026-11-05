// CurlSecretCatalogTests.swift
// ChappieCoreTests
//
// The secret list shown to the model: names, kinds, hosts and reference syntax — never values.

import Testing
import Foundation
@testable import ChappieCore

@Suite("Curl secret catalog")
struct CurlSecretCatalogTests {

    private func entry(_ project: String, _ name: String, _ kind: CurlSecretKind,
                       host: String = "https://dev.x.ru", header: String = "",
                       missing: [CurlSecretField] = []) -> CurlSecretCatalog.Entry {
        CurlSecretCatalog.Entry(
            project: project,
            secret: CurlSecret(name: name, kind: kind, hostOrigin: host, headerName: header),
            missing: missing)
    }

    @Test("Empty list says there are no secrets, so the model asks instead of guessing")
    func empty() {
        let text = CurlSecretCatalog.describe([])
        #expect(text.contains("No secrets are configured"))
    }

    @Test("Login+password secret lists both reference parts and its host")
    func loginPassword() {
        let text = CurlSecretCatalog.describe([entry("SK", "sk", .loginPassword)])
        #expect(text.contains("Project 'SK'"))
        #expect(text.contains("\"sk\": login+password for https://dev.x.ru"))
        #expect(text.contains("{{secret:sk.login}}"))
        #expect(text.contains("{{secret:sk.password}}"))
    }

    @Test("Names with spaces and Cyrillic are shown as they must be typed")
    func unicodeNames() {
        let text = CurlSecretCatalog.describe([entry("SK", "Юлин логин", .loginPassword)])
        #expect(text.contains("{{secret:Юлин логин.login}}"))
    }

    @Test("Custom header shows the header name, token shows value part")
    func kinds() {
        let text = CurlSecretCatalog.describe([
            entry("P", "key", .customHeader, header: "X-Api-Key"),
            entry("P", "bearer", .token)
        ])
        #expect(text.contains("header X-Api-Key"))
        #expect(text.contains("{{secret:key.value}}"))
        #expect(text.contains("{{secret:bearer.value}}"))
    }

    @Test("A secret whose value is not entered is flagged")
    func missingValue() {
        let text = CurlSecretCatalog.describe([entry("P", "sk", .loginPassword, missing: [.password])])
        #expect(text.contains("VALUE NOT ENTERED (password)"))
    }

    @Test("Projects are grouped and sorted; output is deterministic for the provider cache")
    func deterministic() {
        let a = [entry("B", "z", .token), entry("A", "y", .token), entry("A", "x", .token)]
        let text = CurlSecretCatalog.describe(a)
        #expect(text == CurlSecretCatalog.describe(a.reversed()))
        let pa = text.range(of: "Project 'A'")!.lowerBound
        let pb = text.range(of: "Project 'B'")!.lowerBound
        #expect(pa < pb)
        #expect(text.range(of: "\"x\"")!.lowerBound < text.range(of: "\"y\"")!.lowerBound)
    }
}
