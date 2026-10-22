// ThreadStore+Backup.swift
// ChappieCore
//
// Export helpers for BackupService (full-settings export/import, machine migration).
// Read-only — exposes raw ThreadPayload + chunk Data so BackupService can serialize
// them into ChappieExportBundle without ThreadStore depending on BackupModels.

import Foundation

extension ThreadStore {

    /// All thread payloads as-is (settingsJSON + projectsJSON blobs included).
    public func exportAllPayloads() async throws -> [ThreadPayload] {
        return try await loadPayloads()
    }

    /// Raw message chunks for one thread, in index order — opaque Data, untouched.
    public func exportChunks(forThreadId threadId: UUID) async throws -> [ExportedChunk] {
        let indices = try await chunkIndices(for: threadId)
        var result: [ExportedChunk] = []
        result.reserveCapacity(indices.count)

        for index in indices {
            guard let data = try await dataStore.loadRawData(chunkRelation(threadId, index)) else { continue }
            result.append(ExportedChunk(index: index, data: data))
        }
        return result
    }

    // MARK: - Import (full restore, machine migration — see BackupService)

    /// Destructively replaces ALL threads and their message chunks with the imported set.
    /// No merge: existing threads/chunks not present in the import are wiped first.
    public func importAll(
        payloads: [ThreadPayload],
        chunks: [String: [ExportedChunk]]
    ) async throws {
        let existing = try await loadPayloads()
        for thread in existing {
            try await dataStore.deleteByPrefix(ChappieStorageRelation.chunkPrefix(for: thread.id))
        }

        try await savePayloads(payloads)

        for thread in payloads {
            guard let threadChunks = chunks[thread.id.uuidString] else { continue }
            for chunk in threadChunks {
                try await dataStore.saveRawData(chunk.data, for: chunkRelation(thread.id, chunk.index))
            }
        }

        try await refreshCache()
    }
}
