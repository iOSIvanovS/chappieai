// BuiltInProvidersTests.swift
// ChappieCoreTests
//
// Built-in provider presets: the chat path differs per provider, and a wrong path silently
// breaks every model the user adds by hand, so the table is pinned here.

import Testing
import Foundation
@testable import ChappieCore

@Suite("BuiltInProviders")
struct BuiltInProvidersTests {

    @Test("Preset ids are unique and non-empty")
    func uniqueIds() {
        let ids = BuiltInProviders.all.map(\.id)
        #expect(!ids.isEmpty)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Chat paths of providers with non-standard routes")
    func chatPaths() {
        #expect(BuiltInProviders.find(id: "groq")?.chatPath == "/openai/v1/chat/completions")
        #expect(BuiltInProviders.find(id: "openrouter")?.chatPath == "/api/v1/chat/completions")
        #expect(BuiltInProviders.find(id: "anthropic")?.chatPath == "/v1/messages")
        #expect(BuiltInProviders.find(id: "openai")?.chatPath == "/v1/chat/completions")
    }

    @Test("Path prefix is derived from the chat path")
    func pathPrefix() {
        #expect(BuiltInProviders.find(id: "groq")?.pathPrefix == "/openai")
        #expect(BuiltInProviders.find(id: "openrouter")?.pathPrefix == "/api")
        #expect(BuiltInProviders.find(id: "openai")?.pathPrefix == "")
        #expect(BuiltInProviders.find(id: "anthropic")?.pathPrefix == "")
    }

    @Test("Anthropic uses its own protocol, Ollama needs no key")
    func protocolAndKey() {
        #expect(BuiltInProviders.find(id: "anthropic")?.providerProtocol == .anthropic)
        #expect(BuiltInProviders.find(id: "ollama")?.requiresApiKey == false)
        #expect(BuiltInProviders.find(id: "openai")?.requiresApiKey == true)
    }

    @Test("AIProvider resolves its preset through catalogId")
    func providerResolvesPreset() {
        let groq = AIProvider(name: "Groq", baseURL: "https://api.groq.com", catalogId: "groq")
        #expect(groq.defaultChatPath == "/openai/v1/chat/completions")
        #expect(groq.discoveryBaseURL == "https://api.groq.com/openai")
    }

    @Test("Custom providers fall back to protocol defaults")
    func customDefaults() {
        let openai = AIProvider(name: "X", baseURL: "https://x.example", origin: .custom)
        #expect(openai.defaultChatPath == "/v1/chat/completions")
        #expect(openai.discoveryBaseURL == "https://x.example")

        let anthropic = AIProvider(name: "Y", baseURL: "https://y.example", providerProtocol: .anthropic, origin: .custom)
        #expect(anthropic.defaultChatPath == "/v1/messages")
    }

    @Test("Unknown catalogId from an older catalog does not crash and behaves as custom")
    func unknownCatalogId() {
        let p = AIProvider(name: "Old", baseURL: "https://old.example", catalogId: "removed-provider")
        #expect(p.builtIn == nil)
        #expect(p.defaultChatPath == "/v1/chat/completions")
    }
}
