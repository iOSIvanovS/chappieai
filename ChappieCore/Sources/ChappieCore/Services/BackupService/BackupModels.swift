// BackupModels.swift
// ChappieCore
//
// Data models for full-settings export/import (machine migration feature).
//
// SCOPE DECISION (agreed with user):
// Exported: AI providers (incl. API key secrets from Keychain), threads (incl. attached
// projects + their settings/paths), all messages, global/thread/project memory.
// Excluded: message attachments (files on disk) — after import, old attachment
// references become dead links. The app already degrades gracefully for missing
// attachments (see MessageBubbleView+Attachments, ChappieViewModel+Multimodal) —
// no crash, just a text fallback / non-clickable chip. Accepted tradeoff.
//
// WHY MESSAGES ARE RAW Data, NOT ChatMessage:
// ChatMessage is defined in the app target (Chappie/Models/ChatMessage.swift), not in
// ChappieCore. ChappieCore must stay decoupled from app-layer types. Message chunks are
// already stored as raw JSON Data (see ThreadStore+Chunks) — the backup module simply
// carries those bytes through untouched, encode/decode performed by the app layer.
//
// WHY THE WHOLE FILE IS ENCRYPTED, NOT JUST SECRETS:
// Simpler mental model for the user (one password unlocks everything) and avoids
// leaking structural metadata (provider names, thread titles) in a "mostly plaintext"
// file. See BackupCrypto.swift for the encryption scheme.

import Foundation

// MARK: - ChappieExportBundle

/// Root payload serialized to JSON, then encrypted as a whole by BackupCrypto.
public struct ChappieExportBundle: Codable, Sendable {

    public static let currentVersion = 1

    public let version: Int
    public let exportedAt: Date
    public let providers: [ExportedProvider]
    public let threads: [ThreadPayload]
    /// threadId.uuidString -> ordered message chunks (raw JSON Data, opaque to ChappieCore).
    public let messageChunks: [String: [ExportedChunk]]
    public let memory: MemoryStorage

    public init(
        version: Int = ChappieExportBundle.currentVersion,
        exportedAt: Date = Date(),
        providers: [ExportedProvider],
        threads: [ThreadPayload],
        messageChunks: [String: [ExportedChunk]],
        memory: MemoryStorage
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.providers = providers
        self.threads = threads
        self.messageChunks = messageChunks
        self.memory = memory
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case exportedAt    = "exported_at"
        case providers
        case threads
        case messageChunks = "message_chunks"
        case memory
    }
}

// MARK: - ExportedProvider

/// A provider plus its API key secrets pulled out of Keychain.
/// `provider.keys` still holds the APIKey metadata (id/name) — secrets travel separately
/// keyed by key UUID string, mirroring how Keychain storage is keyed.
public struct ExportedProvider: Codable, Sendable {

    public let provider: AIProvider
    /// keyId.uuidString -> plaintext secret. Missing entry = key had no stored secret.
    public let keySecrets: [String: String]

    public init(provider: AIProvider, keySecrets: [String: String]) {
        self.provider = provider
        self.keySecrets = keySecrets
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case keySecrets = "key_secrets"
    }
}

// MARK: - ExportedChunk

/// One message chunk — mirrors the on-disk chunk layout (index + raw encoded array).
public struct ExportedChunk: Codable, Sendable {

    public let index: Int
    public let data: Data

    public init(index: Int, data: Data) {
        self.index = index
        self.data = data
    }
}
