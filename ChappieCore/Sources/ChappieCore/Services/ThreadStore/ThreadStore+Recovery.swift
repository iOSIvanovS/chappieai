// ThreadStore+Recovery.swift
// ChappieCore
//
// Repair of a damaged thread list (backlog 2b).
//
// WHY IT IS POSSIBLE: message chunks are stored under "thread_messages_chunk.<threadUUID>.<n>",
// so the thread ids survive even when the list record itself is destroyed. Rebuilding a thread
// with the SAME id re-attaches its messages and its thread memory (memory scope key = thread UUID).
// What cannot be restored: thread settings, attached projects (and so project memory scopes),
// original thread timestamps (message creation times exist only for messages saved after
// that field was added, and rebuilt threads get synthetic list dates).
//
// WHEN IT RUNS: only when the list record is present but unreadable. A healthy list never
// resurrects chunks without a thread — those are leftovers of an interrupted delete.

import Foundation

extension ThreadStore {

    /// Backup first, then salvage what decodes, then rebuild threads known only by their chunks,
    /// then write the repaired list so the damage is handled exactly once.
    /// Throws (and writes nothing) if the backup cannot be stored.
    func repairDamagedList(_ raw: Data) async throws -> [ThreadPayload] {
        // `raw` may be stale: another caller could have repaired the list while we were suspended.
        if let current = try await dataStore.loadRawData(.threads), current != raw,
           let healthy = try? JSONDecoder().decode([ThreadPayload].self, from: current) {
            return healthy
        }
        let backupKey = try await dataStore.preserveCorruptedRecord(key: ChappieStorageRelation.threads.key, data: raw)

        let elements = try? JSONDecoder().decode([LossyElement<ThreadPayload>].self, from: raw)
        let readable = (elements ?? []).compactMap(\.value)
        let kind: StorageIntegrityIssue.Kind = elements.map {
            .threadListPartial(lostCount: $0.count - readable.count)
        } ?? .threadListUnreadable

        let knownIds = Set(readable.map(\.id))
        let titleHints = Self.titleHints(in: raw)
        var recovered: [ThreadPayload] = []
        let orphans = try await threadIdsWithChunks().subtracting(knownIds)
        for (position, id) in orphans.sorted(by: { $0.uuidString < $1.uuidString }).enumerated() {
            var title = titleHints[id]
            if title == nil { title = try await firstUserMessageTitle(of: id) }
            var payload = ThreadPayload(id: id, title: title ?? recoveredThreadTitle)
            // Messages have no timestamps; distinct dates keep the sidebar order stable.
            let date = Date().addingTimeInterval(-Double(position))
            payload.createdAt = date
            payload.updatedAt = date
            recovered.append(payload)
        }

        let repaired = readable + recovered
        try await savePayloads(repaired)
        pendingIntegrityIssues.append(
            StorageIntegrityIssue(kind: kind, backupKey: backupKey, recoveredCount: recovered.count)
        )
        print("[ThreadStore] ⚠️ Thread list damaged (\(kind)); backup '\(backupKey)', kept \(readable.count), rebuilt \(recovered.count)")
        return repaired
    }

    // MARK: - Helpers

    /// Thread ids that have at least one stored message chunk.
    private func threadIdsWithChunks() async throws -> Set<UUID> {
        let root = ChappieStorageRelation.chunkKeyRoot
        let keys = try await dataStore.keys(withPrefix: root)
        var ids = Set<UUID>()
        for key in keys {
            let rest = key.dropFirst(root.count)
            if let idPart = rest.split(separator: ".", maxSplits: 1).first, let id = UUID(uuidString: String(idPart)) {
                ids.insert(id)
            }
        }
        return ids
    }

    /// Original titles of threads whose entries were too damaged to decode but whose id and title still parse.
    static func titleHints(in raw: Data) -> [UUID: String] {
        guard let array = try? JSONSerialization.jsonObject(with: raw) as? [[String: Any]] else { return [:] }
        var hints: [UUID: String] = [:]
        for entry in array {
            guard let idString = entry["id"] as? String, let id = UUID(uuidString: idString),
                  let title = entry["title"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            hints[id] = title
        }
        return hints
    }

    /// Title from the first user message of the oldest chunk. Reads raw JSON so ChappieCore
    /// does not need the app's message type.
    private func firstUserMessageTitle(of threadId: UUID) async throws -> String? {
        guard let first = try await chunkIndices(for: threadId).first,
              let data = try await dataStore.loadRawData(chunkRelation(threadId, first)),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }

        for item in items {
            let type = item["type"] as? String ?? "message"
            guard type == "message", item["isUser"] as? Bool == true, let text = item["text"] as? String else { continue }
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !line.isEmpty else { continue }
            return line.count > 40 ? String(line.prefix(40)) + "…" : line
        }
        return nil
    }
}
