// BackupServiceTests.swift
// ChappieCoreTests
//
// Verifies full-settings export/import (machine migration feature).
//
// COVERAGE:
// - Export round-trip: providers (incl. Keychain secrets), threads, message chunks, memory.
// - Import is a destructive full restore — pre-existing data must be wiped, not merged.
// - Encrypted end-to-end flow (exportEncrypted → decryptBundle → applyImport).
//
// ISOLATION: each test builds fresh in-memory SQLiteStorage-backed Stores — no shared state.

import Testing
import Foundation
@testable import ChappieCore

// MARK: - Helpers

private func makeStores() throws -> (BackupService, ThreadStore, MemoryStore, AIProviderStore) {
    let storage = try SQLiteStorage(inMemory: true)
    let threadStore = ThreadStore(dataStore: storage)
    let memoryStore = MemoryStore(dataStore: storage)
    let providerStore = AIProviderStore(dataStore: storage)
    let backup = BackupService(threadStore: threadStore, memoryStore: memoryStore, providerStore: providerStore)
    return (backup, threadStore, memoryStore, providerStore)
}

private struct TestMessage: Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    init(text: String) { self.id = UUID(); self.text = text }
}

// MARK: - Suite

@Suite("BackupService export/import")
struct BackupServiceTests {

    @Test("exportBundle captures providers, threads, chunks, and memory")
    func exportCapturesEverything() async throws {
        let (backup, threadStore, memoryStore, providerStore) = try makeStores()

        _ = try await providerStore.addProvider(
            AIProvider(name: "OpenAI", baseURL: "https://api.openai.com"),
            firstKeyName: "Default", firstKeyValue: "sk-secret"
        )
        let threadId = try await threadStore.createThread(title: "Migration test")
        try await threadStore.replaceAllMessages([TestMessage(text: "hello")], toThreadId: threadId)
        try await memoryStore.saveEntry(key: "fact1", type: "fact", jsonString: "{\"a\":1}", scope: "global")

        let bundle = try await backup.exportBundle()

        #expect(bundle.providers.count == 1)
        #expect(bundle.providers[0].keySecrets.values.contains("sk-secret"))
        #expect(bundle.threads.count == 1)
        #expect(bundle.messageChunks[threadId.uuidString]?.isEmpty == false)
        #expect(bundle.memory.scopes["global"]?.first?.key == "fact1")
    }

    @Test("applyImport fully restores providers including Keychain secrets")
    func importRestoresProviderSecrets() async throws {
        let (sourceBackup, _, _, sourceProviders) = try makeStores()
        _ = try await sourceProviders.addProvider(
            AIProvider(name: "Anthropic", baseURL: "https://api.anthropic.com"),
            firstKeyName: "Default", firstKeyValue: "sk-ant-secret"
        )
        let bundle = try await sourceBackup.exportBundle()

        let (targetBackup, _, _, targetProviders) = try makeStores()
        try await targetBackup.applyImport(bundle)

        let imported = try await targetProviders.loadProviders()
        #expect(imported.count == 1)
        #expect(imported[0].name == "Anthropic")
        let keyId = imported[0].keys[0].id
        let secret = await targetProviders.loadApiKey(for: keyId)
        #expect(secret == "sk-ant-secret")
    }

    @Test("applyImport wipes pre-existing providers before restoring (no merge)")
    func importWipesExistingProviders() async throws {
        let (sourceBackup, _, _, sourceProviders) = try makeStores()
        _ = try await sourceProviders.addProvider(
            AIProvider(name: "Imported", baseURL: "https://imported.com"),
            firstKeyName: "k", firstKeyValue: "v-imported"
        )
        let bundle = try await sourceBackup.exportBundle()

        let (targetBackup, _, _, targetProviders) = try makeStores()
        _ = try await targetProviders.addProvider(
            AIProvider(name: "PreExisting", baseURL: "https://preexisting.com"),
            firstKeyName: "k", firstKeyValue: "v-preexisting"
        )

        try await targetBackup.applyImport(bundle)

        let result = try await targetProviders.loadProviders()
        #expect(result.count == 1)
        #expect(result[0].name == "Imported")
    }

    @Test("applyImport fully restores threads and message chunks")
    func importRestoresThreadsAndMessages() async throws {
        let (sourceBackup, sourceThreads, _, _) = try makeStores()
        let threadId = try await sourceThreads.createThread(title: "Original")
        try await sourceThreads.replaceAllMessages([TestMessage(text: "msg1"), TestMessage(text: "msg2")], toThreadId: threadId)
        let bundle = try await sourceBackup.exportBundle()

        let (targetBackup, targetThreads, _, _) = try makeStores()
        try await targetBackup.applyImport(bundle)

        let threads = try await targetThreads.loadThreads()
        #expect(threads.count == 1)
        #expect(threads[0].title == "Original")

        let messages = try await targetThreads.loadAllMessages(fromThreadId: threadId, as: TestMessage.self)
        #expect(messages.count == 2)
        #expect(messages.map(\.text) == ["msg1", "msg2"])
    }

    @Test("applyImport wipes pre-existing threads and their chunks before restoring")
    func importWipesExistingThreads() async throws {
        let (sourceBackup, sourceThreads, _, _) = try makeStores()
        let importedId = try await sourceThreads.createThread(title: "Imported")
        try await sourceThreads.replaceAllMessages([TestMessage(text: "keep")], toThreadId: importedId)
        let bundle = try await sourceBackup.exportBundle()

        let (targetBackup, targetThreads, _, _) = try makeStores()
        let staleId = try await targetThreads.createThread(title: "Stale")
        try await targetThreads.replaceAllMessages([TestMessage(text: "should be wiped")], toThreadId: staleId)

        try await targetBackup.applyImport(bundle)

        let threads = try await targetThreads.loadThreads()
        #expect(threads.count == 1)
        #expect(threads[0].id == importedId)

        let staleMessages = try await targetThreads.loadAllMessages(fromThreadId: staleId, as: TestMessage.self)
        #expect(staleMessages.isEmpty)
    }

    @Test("applyImport fully restores memory, replacing all existing scopes")
    func importRestoresMemory() async throws {
        let (sourceBackup, _, sourceMemory, _) = try makeStores()
        try await sourceMemory.saveEntry(key: "rule1", type: "rule", jsonString: "{}", scope: "global")
        let bundle = try await sourceBackup.exportBundle()

        let (targetBackup, _, targetMemory, _) = try makeStores()
        try await targetMemory.saveEntry(key: "stale_rule", type: "rule", jsonString: "{}", scope: "global")

        try await targetBackup.applyImport(bundle)

        let entries = try await targetMemory.readAllEntries(scope: "global")
        #expect(entries.count == 1)
        #expect(entries[0].key == "rule1")
    }

    @Test("End-to-end encrypted flow: exportEncrypted -> decryptBundle -> applyImport")
    func encryptedEndToEnd() async throws {
        let (sourceBackup, sourceThreads, _, sourceProviders) = try makeStores()
        _ = try await sourceProviders.addProvider(
            AIProvider(name: "Full", baseURL: "https://full.com"),
            firstKeyName: "k", firstKeyValue: "sk-full"
        )
        _ = try await sourceThreads.createThread(title: "Full flow")

        let encrypted = try await sourceBackup.exportEncrypted(password: "migrate-me")

        let (targetBackup, targetThreads, _, targetProviders) = try makeStores()
        let bundle = try await targetBackup.decryptBundle(encrypted, password: "migrate-me")
        try await targetBackup.applyImport(bundle)

        let providers = try await targetProviders.loadProviders()
        let threads = try await targetThreads.loadThreads()
        #expect(providers.count == 1)
        #expect(threads.count == 1)
    }

    @Test("decryptBundle throws on wrong password")
    func decryptWrongPassword() async throws {
        let (backup, _, _, _) = try makeStores()
        let encrypted = try await backup.exportEncrypted(password: "correct")

        await #expect(throws: BackupCryptoError.wrongPasswordOrCorrupted) {
            _ = try await backup.decryptBundle(encrypted, password: "wrong")
        }
    }
}
