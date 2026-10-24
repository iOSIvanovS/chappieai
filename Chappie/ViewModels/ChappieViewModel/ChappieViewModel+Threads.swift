// ChappieViewModel+Threads.swift
// Chappie
//
// Thread lifecycle: load, select, create, confirm, cancel, delete, rename.
// Provider resolution → ChappieViewModel+ThreadProvider.swift
// Welcome greeting   → ChappieViewModel+ThreadGreeting.swift
// Settings update    → ChappieViewModel+ThreadSettings.swift

import SwiftUI
import ChappieCore

extension ChappieViewModel {

    // MARK: - Load & Select

    func loadThreadsAndSelectActive(from store: ThreadStore) async {
        do {
            let loaded = try await store.loadThreads()
            self.threads = loaded

            if loaded.isEmpty {
                let newId = try await store.createThread(title: String(localized: "new_thread.name_placeholder"))
                let refreshed = try await store.loadThreads()
                self.threads = refreshed
                if let newThread = refreshed.first(where: { $0.id == newId }) {
                    await selectThread(newThread)
                }
            } else {
                if let lastId = loadLastActiveThreadId(),
                   let lastThread = loaded.first(where: { $0.id == lastId }) {
                    await selectThread(lastThread)
                } else if let current = activeThread,
                          let updated = loaded.first(where: { $0.id == current.id }) {
                    self.activeThread = updated
                    buildAndSyncMemoryContext()
                } else {
                    await selectThread(loaded[0])
                }
            }
        } catch {
            print("[ChappieViewModel] Error loading threads: \(error)")
        }
    }

    /// Selects a thread and loads its messages.
    ///
    /// - Parameter insertGreeting: pass true for brand-new threads — greeting is inserted
    ///   inside _syncTask after loadMessages(), so it is never overwritten by the loaded array.
    func selectThread(_ thread: ThreadMetadata, insertGreeting: Bool = false) async {
        guard let store = threadStore else { return }

        // Cancel any in-flight background sync from a previous thread switch.
        _syncTask?.cancel()
        _syncTask = nil

        self.isLoadingThread = true
        self.isLoadingMessages = true
        self.messages = []
        self.displayedMessages = []
        // Window bookkeeping belongs to the previous thread; a stale index would make the next
        // save write chunks at the wrong position.
        self.oldestLoadedChunkIndex = nil
        self.hasMoreChunks = false
        self.activeThread = thread
        self._activeThreadSession = nil

        saveLastActiveThreadId(thread.id)

        let settings = (try? await store.loadSettings(forThreadId: thread.id)) ?? ThreadSettings()
        self.activeThreadSettings = settings

        await resolveAndApplyProvider(for: thread, settings: settings)

        self.isLoadingThread = false
        self.isAppReady = true

        _syncTask = Task { [weak self] in
            guard let self else { return }

            // Step 1: load last chunk of messages — fast O(1) open regardless of history size.
            if let result = try? await store.loadMessages(fromThreadId: thread.id, as: ChatMessage.self) {
                guard !Task.isCancelled else { return }
                self.messages = result.messages
                self.hasMoreChunks = result.hasMore
                if result.hasMore {
                    self.oldestLoadedChunkIndex = try? await store.lastChunkIndex(forThreadId: thread.id)
                }
                self.resetPagination(fireScrollTrigger: true)
                print("[ChappieViewModel] Thread '\(thread.title)' selected (\(result.messages.count) messages, hasMoreChunks=\(result.hasMore))")
            }

            // Step 1a: insert greeting for new threads — AFTER loadMessages so it is never overwritten.
            // WHY HERE: confirmNewThread() calls selectThread() which starts _syncTask.
            // If greeting were inserted after selectThread() returns, _syncTask would overwrite it
            // with the empty array from loadMessages(). Inserting here guarantees correct order.
            if insertGreeting {
                await self.insertStaticWelcomeGreeting(for: thread)
            }

            self.isLoadingMessages = false

            guard !Task.isCancelled else { return }

            // Step 2: load projects.
            await self.loadProjectsForThread(thread)

            guard !Task.isCancelled else { return }

            // Step 3: memory context — once, here. syncFileSystemForActiveThread() does NOT call it.
            self.buildAndSyncMemoryContext()
            await self.syncActiveMemoryContext()
            self.refreshBalanceForActiveProvider()

            guard !Task.isCancelled else { return }

            // Step 4: full session assembly (FS sync + MCP restart — once, inside assembleThreadSession).
            await self.assembleThreadSession(for: thread)
        }
    }

    // MARK: - Load More Chunks (scroll to top)

    /// Loads the previous chunk when user scrolls to the top of the thread.
    /// Called from ChatScrollView when hasMoreChunks == true and user hits the top.
    func loadOlderMessages() {
        guard hasMoreChunks,
              let threadId = activeThread?.id,
              let store = threadStore,
              let currentOldest = oldestLoadedChunkIndex else { return }

        Task {
            guard let result = try? await store.loadMoreMessages(
                fromThreadId: threadId,
                currentOldestChunkIndex: currentOldest,
                as: ChatMessage.self
            ) else { return }

            guard !result.messages.isEmpty else { return }

            // Prepend older messages — preserve scroll anchor via loadMoreAnchorId.
            self.loadMoreAnchorId = self.displayedMessages.first?.id
            self.messages = result.messages + self.messages
            self.displayedMessages = result.messages + self.displayedMessages
            self.displayedStart += result.messages.count
            self.hasMoreChunks = result.hasMore
            self.oldestLoadedChunkIndex = result.newOldestChunkIndex
        }
    }

    // MARK: - Create / Confirm / Cancel

    func createNewThread() {
        guard let store = threadStore else { return }

        Task {
            do {
                let newId = try await store.createThread(title: String(localized: "new_thread.name_placeholder"))
                let refreshed = try await store.loadThreads()
                self.threads = refreshed

                if let newThread = refreshed.first(where: { $0.id == newId }) {
                    if !providers.isEmpty {
                        self.pendingNewThread = newThread
                        self.showNewThreadProviderPicker = true
                    } else {
                        // No providers configured — select thread without greeting.
                        await selectThread(newThread)
                        self.activeProjects = []
                        buildAndSyncMemoryContext()
                        await syncActiveMemoryContext()
                    }
                }
                print("[ChappieViewModel] New thread created")
            } catch {
                print("[ChappieViewModel] Error creating thread: \(error)")
            }
        }
    }

    func confirmNewThread(
        with providerId: UUID,
        keyId: UUID?,
        modelName: String,
        title: String,
        settings: ThreadSettings
    ) async {
        guard let thread = pendingNewThread, let store = threadStore else { return }
        self.pendingNewThread = nil
        self.showNewThreadProviderPicker = false

        if let provider = providers.first(where: { $0.id == providerId }) {
            await switchProvider(
                provider,
                keyId: keyId,
                modelName: modelName.isEmpty ? nil : modelName,
                persistSettings: false
            )
        }

        let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = finalTitle.isEmpty ? String(localized: "new_thread.name_placeholder") : finalTitle
        try? await store.renameThread(id: thread.id, title: resolvedTitle)

        var updatedSettings = settings
        updatedSettings.activeProviderId = providerId
        updatedSettings.activeKeyId = keyId
        updatedSettings.activeModelName = modelName.isEmpty ? nil : modelName
        try? await store.updateSettings(updatedSettings, forThreadId: thread.id)

        let refreshed = (try? await store.loadThreads()) ?? []
        self.threads = refreshed
        let updatedThread = refreshed.first(where: { $0.id == thread.id }) ?? thread

        // insertGreeting: true — greeting is inserted inside _syncTask after loadMessages(),
        // so it is never overwritten by the empty array returned from storage.
        await selectThread(updatedThread, insertGreeting: true)
    }

    func cancelNewThread() {
        guard let thread = pendingNewThread else { return }
        self.pendingNewThread = nil
        self.showNewThreadProviderPicker = false

        guard let store = threadStore else { return }
        Task {
            try? await store.deleteThread(id: thread.id)
            if let refreshed = try? await store.loadThreads() { self.threads = refreshed }
        }
    }

    // MARK: - Delete / Rename

    func deleteThread(_ thread: ThreadMetadata) {
        guard let store = threadStore else { return }
        threadDrafts.removeValue(forKey: thread.id)

        Task {
            do {
                try await store.deleteThread(id: thread.id)
                let refreshed = try await store.loadThreads()
                self.threads = refreshed

                if activeThread?.id == thread.id {
                    if let first = refreshed.first {
                        await selectThread(first)
                    } else {
                        let newId = try await store.createThread(title: String(localized: "new_thread.name_placeholder"))
                        let withNew = try await store.loadThreads()
                        self.threads = withNew
                        if let newThread = withNew.first(where: { $0.id == newId }) {
                            await selectThread(newThread)
                        }
                    }
                }
                print("[ChappieViewModel] Thread '\(thread.title)' deleted")
            } catch {
                print("[ChappieViewModel] Error deleting thread: \(error)")
            }
        }
    }

    func renameThread(_ thread: ThreadMetadata, newTitle: String) {
        guard let store = threadStore else { return }

        Task {
            do {
                try await store.renameThread(id: thread.id, title: newTitle)
                let refreshed = try await store.loadThreads()
                self.threads = refreshed

                if activeThread?.id == thread.id,
                   let updated = refreshed.first(where: { $0.id == thread.id }) {
                    self.activeThread = updated
                }
            } catch {
                print("[ChappieViewModel] Error renaming thread: \(error)")
            }
        }
    }
}
