// BackupService.swift
// ChappieCore
//
// Assembles a ChappieExportBundle from the live Stores and produces the final
// encrypted file bytes. Pure ChappieCore — no app-layer types involved, since
// message chunks travel as opaque Data (see ThreadStore+Backup, BackupModels).
//
// SCOPE (agreed with user): providers (incl. Keychain secrets), threads (incl.
// attached projects/settings/paths), all messages, global/thread/project memory.
// Excluded: attachments on disk (see BackupModels.swift header for rationale).

import Foundation

// MARK: - BackupService

public actor BackupService {

    private let threadStore: ThreadStore
    private let memoryStore: MemoryStore
    private let providerStore: AIProviderStore

    public init(threadStore: ThreadStore, memoryStore: MemoryStore, providerStore: AIProviderStore) {
        self.threadStore = threadStore
        self.memoryStore = memoryStore
        self.providerStore = providerStore
    }

    // MARK: - Export

    /// Assembles the full bundle from live Stores. Secrets are pulled from Keychain here.
    public func exportBundle() async throws -> ChappieExportBundle {
        let providers = try await providerStore.loadProviders()
        var exportedProviders: [ExportedProvider] = []
        exportedProviders.reserveCapacity(providers.count)

        for provider in providers {
            var secrets: [String: String] = [:]
            for key in provider.keys {
                if let secret = await providerStore.loadApiKey(for: key.id) {
                    secrets[key.id.uuidString] = secret
                }
            }
            exportedProviders.append(ExportedProvider(provider: provider, keySecrets: secrets))
        }

        let threads = try await threadStore.exportAllPayloads()
        var messageChunks: [String: [ExportedChunk]] = [:]
        messageChunks.reserveCapacity(threads.count)

        for thread in threads {
            let chunks = try await threadStore.exportChunks(forThreadId: thread.id)
            if !chunks.isEmpty {
                messageChunks[thread.id.uuidString] = chunks
            }
        }

        let memory = try await memoryStore.exportStorage()

        return ChappieExportBundle(
            providers: exportedProviders,
            threads: threads,
            messageChunks: messageChunks,
            memory: memory
        )
    }

    /// Serializes + encrypts the bundle in one step — ready to write to disk.
    public func exportEncrypted(password: String) async throws -> Data {
        let bundle = try await exportBundle()
        let plaintext = try JSONEncoder().encode(bundle)
        return try BackupCrypto.encrypt(plaintext, password: password)
    }

    // MARK: - Import (full restore — no merge, see BackupModels.swift header)

    /// Decrypts and parses the backup file — call before `applyImport` to let the
    /// caller show a confirmation/warning dialog using the bundle's `exportedAt` date.
    public func decryptBundle(_ data: Data, password: String) throws -> ChappieExportBundle {
        let plaintext = try BackupCrypto.decrypt(data, password: password)
        return try JSONDecoder().decode(ChappieExportBundle.self, from: plaintext)
    }

    /// Destructively overwrites providers, threads, messages, and memory with the
    /// imported bundle. Project folder paths and attachments are not part of the
    /// bundle — the user reconnects them manually after import (see BackupModels.swift).
    public func applyImport(_ bundle: ChappieExportBundle) async throws {
        try await providerStore.importAll(bundle.providers)

        var chunksByThread: [String: [ExportedChunk]] = [:]
        for (threadId, chunks) in bundle.messageChunks { chunksByThread[threadId] = chunks }
        try await threadStore.importAll(payloads: bundle.threads, chunks: chunksByThread)

        try await memoryStore.importStorage(bundle.memory)

        print("[BackupService] 📦 Full restore applied: \(bundle.providers.count) providers, \(bundle.threads.count) threads")
    }
}
