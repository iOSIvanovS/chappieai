// ThreadStore+Settings.swift
// ChappieCore
//
// Thread settings CRUD and memory footprint reporting.

import Foundation

extension ThreadStore {

    // MARK: - Settings

    public func updateSettings(_ settings: ThreadSettings, forThreadId threadId: UUID) async throws {
        var payloads = try await loadPayloads()
        guard let idx = payloads.firstIndex(where: { $0.id == threadId }) else { return }
        payloads[idx].settingsJSON = (try? JSONEncoder().encode(settings)) ?? payloads[idx].settingsJSON
        try await savePayloads(payloads)
        try await refreshCache()
    }

    public func loadSettings(forThreadId threadId: UUID) async throws -> ThreadSettings {
        let payloads = try await loadPayloads()
        guard let payload = payloads.first(where: { $0.id == threadId }),
              !payload.settingsJSON.isEmpty,
              let settings = try? JSONDecoder().decode(ThreadSettings.self, from: payload.settingsJSON)
        else { return ThreadSettings() }
        return settings
    }

    // MARK: - Memory footprint

    /// Returns per-thread memory stats — used by MemoryManagementView.
    public func loadMemoryInfo() async throws -> [ThreadMemoryInfo] {
        let payloads = try await loadPayloads()
        var result: [ThreadMemoryInfo] = []

        for payload in payloads.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let indices = try await chunkIndices(for: payload.id)

            var totalSize = 0
            var totalCount = 0

            for index in indices {
                guard let data = try await dataStore.loadRawData(chunkRelation(payload.id, index)) else { continue }
                totalSize += data.count
                if let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                    totalCount += arr.count
                }
            }

            result.append(ThreadMemoryInfo(
                threadId: payload.id,
                title: payload.title,
                messageCount: totalCount,
                sizeBytes: totalSize,
                chunkCount: max(1, indices.count)
            ))
        }

        return result
    }
}
