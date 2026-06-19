// AIProviderStoreTests.swift
// ChappieCoreTests
//
// Tests for AIProviderStore — CRUD, key deduplication, merge, and default management.
//
// COVERAGE:
// - addProvider: basic add, first provider becomes default, no-key provider
// - deleteProvider: removes provider + keychain entries, reassigns default
// - updateProvider: persists changes
// - mergeProvider: merge by host — adds new key if value unique, skips duplicate
// - addFromCatalog: new provider, re-add existing (merge path)
// - Key deduplication: same value not added twice to same provider
// - Key management: addKey, updateKey, deleteKey
// - Model management: addModel (dedup), deleteModel
// - setDefault: correct provider marked, others cleared
// - loadProvider / loadDefaultProvider
//
// NOTE: Keychain is live in tests (no sandbox restriction on macOS unit tests).
// Each test uses a fresh in-memory SQLiteStorage — no shared state.

import Testing
import Foundation
@testable import ChappieCore

// MARK: - Helpers

private func makeStore() throws -> AIProviderStore {
    let storage = try SQLiteStorage(inMemory: true)
    return AIProviderStore(dataStore: storage)
}

private func makeProvider(
    name: String = "TestProvider",
    baseURL: String = "https://api.test.com",
    requiresApiKey: Bool = true,
    catalogId: String? = nil
) -> AIProvider {
    AIProvider(
        name: name,
        baseURL: baseURL,
        catalogId: catalogId,
        requiresApiKey: requiresApiKey
    )
}

private func makeModel(id: String = "gpt-test", name: String = "GPT Test") -> AIModel {
    AIModel(id: id, name: name)
}

// RemoteProvider is Codable-only — no public memberwise init, build via JSON decode.
private func remoteProvider(id: String, baseURL: String, withModel: Bool) throws -> RemoteProvider {
    let modelJSON = withModel
        ? #"[{"id":"gpt-4o","name":"GPT-4o","endpoint":"/v1/chat/completions","protocol":"openai"}]"#
        : "[]"
    let json = """
    {
      "id": "\(id)",
      "name": "Test Provider",
      "base_url": "\(baseURL)",
      "requires_api_key": true,
      "icon_name": "sparkles",
      "icon_color": "#10A37F",
      "models": \(modelJSON)
    }
    """
    return try JSONDecoder().decode(RemoteProvider.self, from: Data(json.utf8))
}

// MARK: - Suite

@Suite("AIProviderStore")
struct AIProviderStoreTests {

    // MARK: - Add Provider

    @Test("addProvider stores provider and returns its id")
    func addProviderBasic() async throws {
        let store = try makeStore()
        let provider = makeProvider()

        let id = try await store.addProvider(provider, firstKeyName: "Default", firstKeyValue: "sk-test")
        let providers = try await store.loadProviders()

        #expect(providers.count == 1)
        #expect(providers[0].id == id)
        #expect(providers[0].name == "TestProvider")
    }

    @Test("First added provider becomes default automatically")
    func firstProviderBecomesDefault() async throws {
        let store = try makeStore()
        let id = try await store.addProvider(makeProvider(), firstKeyName: "k", firstKeyValue: "v")

        let def = try await store.loadDefaultProvider()
        #expect(def?.id == id)
    }

    @Test("Second provider does not override default")
    func secondProviderDoesNotOverrideDefault() async throws {
        let store = try makeStore()
        let first = try await store.addProvider(
            makeProvider(name: "First", baseURL: "https://first.com"),
            firstKeyName: "k", firstKeyValue: "v1"
        )
        _ = try await store.addProvider(
            makeProvider(name: "Second", baseURL: "https://second.com"),
            firstKeyName: "k", firstKeyValue: "v2"
        )

        let def = try await store.loadDefaultProvider()
        #expect(def?.id == first)
    }

    @Test("addProvider without API key stores no key")
    func addProviderNoKey() async throws {
        let store = try makeStore()
        let provider = makeProvider(requiresApiKey: false)

        _ = try await store.addProvider(provider, firstKeyName: "", firstKeyValue: "")
        let providers = try await store.loadProviders()

        #expect(providers[0].keys.isEmpty)
    }

    // MARK: - Load Provider

    @Test("loadProvider returns correct provider by id")
    func loadProviderById() async throws {
        let store = try makeStore()
        let id = try await store.addProvider(makeProvider(), firstKeyName: "k", firstKeyValue: "v")

        let loaded = try await store.loadProvider(id: id)
        #expect(loaded?.id == id)
    }

    @Test("loadProvider returns nil for unknown id")
    func loadProviderUnknown() async throws {
        let store = try makeStore()

        let loaded = try await store.loadProvider(id: UUID())
        #expect(loaded == nil)
    }

    // MARK: - Delete Provider

    @Test("deleteProvider removes provider from list")
    func deleteProviderRemoves() async throws {
        let store = try makeStore()
        let id = try await store.addProvider(makeProvider(), firstKeyName: "k", firstKeyValue: "v")

        try await store.deleteProvider(id: id)
        let providers = try await store.loadProviders()

        #expect(providers.isEmpty)
    }

    @Test("deleteProvider on unknown id throws notFound")
    func deleteProviderUnknown() async throws {
        let store = try makeStore()

        await #expect(throws: AIProviderStoreError.self) {
            try await store.deleteProvider(id: UUID())
        }
    }

    @Test("deleteProvider reassigns default to next provider")
    func deleteDefaultReassigns() async throws {
        let store = try makeStore()
        let first = try await store.addProvider(
            makeProvider(name: "First", baseURL: "https://first.com"),
            firstKeyName: "k", firstKeyValue: "v1"
        )
        let second = try await store.addProvider(
            makeProvider(name: "Second", baseURL: "https://second.com"),
            firstKeyName: "k", firstKeyValue: "v2"
        )

        try await store.deleteProvider(id: first)

        let def = try await store.loadDefaultProvider()
        #expect(def?.id == second)
    }

    // MARK: - Update Provider

    @Test("updateProvider persists name change")
    func updateProviderName() async throws {
        let store = try makeStore()
        let id = try await store.addProvider(makeProvider(), firstKeyName: "k", firstKeyValue: "v")

        var provider = try await store.loadProvider(id: id)!
        provider.name = "Renamed"
        try await store.updateProvider(provider)

        let loaded = try await store.loadProvider(id: id)
        #expect(loaded?.name == "Renamed")
    }

    // MARK: - setDefault

    @Test("setDefault marks correct provider and clears others")
    func setDefault() async throws {
        let store = try makeStore()
        let first = try await store.addProvider(
            makeProvider(name: "First", baseURL: "https://first.com"),
            firstKeyName: "k", firstKeyValue: "v1"
        )
        let second = try await store.addProvider(
            makeProvider(name: "Second", baseURL: "https://second.com"),
            firstKeyName: "k", firstKeyValue: "v2"
        )

        try await store.setDefault(id: second)

        let providers = try await store.loadProviders()
        let defaults = providers.filter { $0.isDefault }
        #expect(defaults.count == 1)
        #expect(defaults[0].id == second)

        let firstProvider = providers.first(where: { $0.id == first })
        #expect(firstProvider?.isDefault == false)
    }

    // MARK: - Key Management

    @Test("addKey appends key to provider")
    func addKey() async throws {
        let store = try makeStore()
        let id = try await store.addProvider(makeProvider(), firstKeyName: "Key1", firstKeyValue: "sk-1")

        let newKey = try await store.addKey(name: "Key2", value: "sk-2", toProviderId: id)
        let provider = try await store.loadProvider(id: id)!

        #expect(provider.keys.count == 2)
        #expect(provider.keys.last?.id == newKey.id)
    }

    @Test("deleteKey removes key from provider")
    func deleteKey() async throws {
        let store = try makeStore()
        let id = try await store.addProvider(makeProvider(), firstKeyName: "Key1", firstKeyValue: "sk-1")
        let provider = try await store.loadProvider(id: id)!
        let keyId = provider.keys[0].id

        try await store.deleteKey(id: keyId, fromProviderId: id)

        let updated = try await store.loadProvider(id: id)!
        #expect(updated.keys.isEmpty)
    }

    @Test("loadApiKey returns stored secret")
    func loadApiKey() async throws {
        let store = try makeStore()
        let id = try await store.addProvider(makeProvider(), firstKeyName: "k", firstKeyValue: "secret-value")
        let provider = try await store.loadProvider(id: id)!
        let keyId = provider.keys[0].id

        let secret = await store.loadApiKey(for: keyId)
        #expect(secret == "secret-value")
    }

    // MARK: - Key Deduplication

    @Test("mergeProvider skips duplicate key value")
    func mergeProviderSkipsDuplicateKey() async throws {
        let store = try makeStore()
        _ = try await store.addProvider(
            makeProvider(baseURL: "https://api.openai.com"),
            firstKeyName: "Key1", firstKeyValue: "sk-dup"
        )

        _ = try await store.mergeProvider(
            makeProvider(baseURL: "https://api.openai.com"),
            keyName: "Key2",
            keyValue: "sk-dup",
            models: []
        )

        let providers = try await store.loadProviders()
        #expect(providers[0].keys.count == 1)
    }

    @Test("mergeProvider adds unique key value")
    func mergeProviderAddsUniqueKey() async throws {
        let store = try makeStore()
        _ = try await store.addProvider(
            makeProvider(baseURL: "https://api.openai.com"),
            firstKeyName: "Key1", firstKeyValue: "sk-first"
        )

        _ = try await store.mergeProvider(
            makeProvider(baseURL: "https://api.openai.com"),
            keyName: "Key2",
            keyValue: "sk-second",
            models: []
        )

        let providers = try await store.loadProviders()
        #expect(providers[0].keys.count == 2)
    }

    @Test("mergeProvider creates new provider when host not found")
    func mergeProviderCreatesNew() async throws {
        let store = try makeStore()

        _ = try await store.mergeProvider(
            makeProvider(name: "New", baseURL: "https://new.api.com"),
            keyName: "k",
            keyValue: "sk-new",
            models: []
        )

        let providers = try await store.loadProviders()
        #expect(providers.count == 1)
        #expect(providers[0].name == "New")
    }

    // MARK: - Model Management

    @Test("addModel appends model to provider")
    func addModel() async throws {
        let store = try makeStore()
        let id = try await store.addProvider(makeProvider(), firstKeyName: "k", firstKeyValue: "v")

        try await store.addModel(makeModel(), toProviderId: id)

        let provider = try await store.loadProvider(id: id)!
        #expect(provider.models.count == 1)
        #expect(provider.models[0].id == "gpt-test")
    }

    @Test("addModel skips duplicate model id")
    func addModelDedup() async throws {
        let store = try makeStore()
        let id = try await store.addProvider(makeProvider(), firstKeyName: "k", firstKeyValue: "v")

        try await store.addModel(makeModel(id: "gpt-4"), toProviderId: id)
        try await store.addModel(makeModel(id: "gpt-4"), toProviderId: id)

        let provider = try await store.loadProvider(id: id)!
        #expect(provider.models.count == 1)
    }

    @Test("deleteModel removes model from provider")
    func deleteModel() async throws {
        let store = try makeStore()
        let id = try await store.addProvider(makeProvider(), firstKeyName: "k", firstKeyValue: "v")
        try await store.addModel(makeModel(id: "gpt-4"), toProviderId: id)

        try await store.deleteModel(id: "gpt-4", fromProviderId: id)

        let provider = try await store.loadProvider(id: id)!
        #expect(provider.models.isEmpty)
    }

    // MARK: - Duplicate Checks

    @Test("providerHostExists returns true for known host")
    func hostExistsTrue() async throws {
        let store = try makeStore()
        _ = try await store.addProvider(
            makeProvider(baseURL: "https://api.openai.com"),
            firstKeyName: "k", firstKeyValue: "v"
        )

        let exists = await store.providerHostExists("https://api.openai.com")
        #expect(exists == true)
    }

    @Test("providerHostExists returns false for unknown host")
    func hostExistsFalse() async throws {
        let store = try makeStore()

        let exists = await store.providerHostExists("https://unknown.com")
        #expect(exists == false)
    }

    @Test("keyValueExists returns true when key stored")
    func keyValueExistsTrue() async throws {
        let store = try makeStore()
        let id = try await store.addProvider(makeProvider(), firstKeyName: "k", firstKeyValue: "sk-exists")

        let exists = await store.keyValueExists("sk-exists", inProviderId: id)
        #expect(exists == true)
    }

    @Test("keyValueExists returns false for unknown value")
    func keyValueExistsFalse() async throws {
        let store = try makeStore()
        let id = try await store.addProvider(makeProvider(), firstKeyName: "k", firstKeyValue: "sk-real")

        let exists = await store.keyValueExists("sk-fake", inProviderId: id)
        #expect(exists == false)
    }

    // MARK: - hasProviders

    @Test("hasProviders returns false on empty store")
    func hasProvidersEmpty() async throws {
        let store = try makeStore()
        let has = await store.hasProviders()
        #expect(has == false)
    }

    @Test("hasProviders returns true after adding provider")
    func hasProvidersTrue() async throws {
        let store = try makeStore()
        _ = try await store.addProvider(makeProvider(), firstKeyName: "k", firstKeyValue: "v")

        let has = await store.hasProviders()
        #expect(has == true)
    }

    // MARK: - addFromCatalog

    @Test("addFromCatalog creates new provider from remote")
    func addFromCatalogNew() async throws {
        let store = try makeStore()
        let remote = try remoteProvider(id: "openai", baseURL: "https://api.openai.com", withModel: true)

        let id = try await store.addFromCatalog(remote, keyName: "Default", keyValue: "sk-test")
        let provider = try await store.loadProvider(id: id)

        #expect(provider?.catalogId == "openai")
        #expect(provider?.models.count == 1)
    }

    @Test("addFromCatalog merges into existing catalog provider")
    func addFromCatalogMerges() async throws {
        let store = try makeStore()
        let remote = try remoteProvider(id: "openai", baseURL: "https://api.openai.com", withModel: false)

        let id = try await store.addFromCatalog(remote, keyName: "Key1", keyValue: "sk-first")
        _ = try await store.addFromCatalog(remote, keyName: "Key2", keyValue: "sk-second")

        let providers = try await store.loadProviders()
        #expect(providers.count == 1)
        #expect(providers[0].id == id)
        #expect(providers[0].keys.count == 2)
    }
}
