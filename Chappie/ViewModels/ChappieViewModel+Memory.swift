// ChappieViewModel+Memory.swift
// Chappie
//
// Memory operations: SwiftData memory store, system prompt context sync,
// thread memory stats, and deletion.

import Foundation
import ChappieCore

extension ChappieViewModel {

    // MARK: - Memory Context Sync

    /// Rebuilds activeMemoryContext from the current thread + projects.
    /// Called after thread switch, project add/remove, or memory write.
    func buildAndSyncMemoryContext() {
        guard let thread = activeThread else {
            activeMemoryContext = .empty
            return
        }

        let projectInfos = activeProjects.map { project in
            MemoryContext.ProjectInfo(
                id: project.id,
                name: project.displayName,
                settings: project.settings
            )
        }

        activeMemoryContext = MemoryContext(
            threadId: thread.id,
            projectInfos: projectInfos
        )
    }

    /// Async version — rebuilds context and invalidates ThreadSession cache.
    func syncActiveMemoryContext() async {
        buildAndSyncMemoryContext()
        await _activeThreadSession?.invalidateCache()
    }

    // MARK: - Memory Store (tool-facing)

    func saveMemory(key: String, type: String, value: String, scope: String) async {
        guard let store = memoryStore else { return }
        do {
            try await store.saveEntry(key: key, type: type, jsonString: value, scope: scope)
            await _activeThreadSession?.invalidateCache()
        } catch {
            print("[ChappieViewModel] Failed to save memory: \(error)")
        }
    }

    func recallMemory(key: String, scope: String) async -> String? {
        guard let store = memoryStore else { return nil }
        return try? await store.readEntry(key: key, scope: scope)
    }

    func deleteMemory(key: String, scope: String) async {
        guard let store = memoryStore else { return }
        do {
            try await store.deleteEntry(key: key, scope: scope)
            await _activeThreadSession?.invalidateCache()
        } catch {
            print("[ChappieViewModel] Failed to delete memory: \(error)")
        }
    }

    // MARK: - Thread Memory Stats (for MemoryManagementView)

    struct ThreadMemoryStat: Sendable {
        let id: UUID
        let title: String
        let messageCount: Int
        let bytes: Int
    }

    /// Loads message count and raw JSON size for all threads.
    func loadThreadMemoryStats() async -> [ThreadMemoryStat] {
        guard let threadStore else { return [] }
        do {
            let allThreads = try await threadStore.loadThreads()
            var stats: [ThreadMemoryStat] = []
            for thread in allThreads {
                let (count, bytes) = (try? await threadStore.messageStats(forThreadId: thread.id)) ?? (0, 0)
                stats.append(ThreadMemoryStat(
                    id: thread.id,
                    title: thread.title,
                    messageCount: count,
                    bytes: bytes
                ))
            }
            return stats.sorted { $0.bytes > $1.bytes }
        } catch {
            print("[ChappieViewModel] Failed to load thread memory stats: \(error)")
            return []
        }
    }

    /// Deletes oldest N messages from a thread. Reloads active thread messages if needed.
    func deleteOldestMessages(count: Int, fromThreadId threadId: UUID) async {
        guard let threadStore else { return }
        do {
            try await threadStore.deleteOldestMessages(count: count, fromThreadId: threadId)
            print("[ChappieViewModel] Deleted \(count) oldest messages from thread \(threadId)")

            if activeThread?.id == threadId {
                await reloadActiveThreadMessages()
            }
        } catch {
            print("[ChappieViewModel] Failed to delete messages: \(error)")
        }
    }

    // MARK: - Reload Active Thread Messages

    private func reloadActiveThreadMessages() async {
        guard let threadId = activeThread?.id, let store = threadStore else { return }
        do {
            let loaded = try await store.loadMessages(fromThreadId: threadId, as: ChatMessage.self)
            messages = loaded
            resetPagination(fireScrollTrigger: true)
        } catch {
            print("[ChappieViewModel] Failed to reload messages: \(error)")
        }
    }
}
