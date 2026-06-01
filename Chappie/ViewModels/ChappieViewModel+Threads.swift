// ChappieViewModel+Threads.swift
// Chappie
//
// Thread lifecycle: load, select, create, confirm, cancel, delete, rename, settings update.

import SwiftUI
import ChappieCore
import SwiftData

extension ChappieViewModel {

    // MARK: - Load & Select

    func loadThreadsAndSelectActive(from store: ThreadStore) async {
        do {
            let loaded = try await store.loadThreads()
            self.threads = loaded

            if loaded.isEmpty {
                let newId = try await store.createThread(title: "Новый тред")
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

    func selectThread(_ thread: ThreadMetadata) async {
        guard let store = threadStore else { return }

        // Show spinner immediately — before activeThread is assigned (prevents welcome screen flash)
        self.isLoadingThread = true
        self.messages = []
        self.displayedMessages = []
        self.activeThread = thread

        // V2: discard previous session immediately on thread switch
        if FeatureFlags.useThreadIsolationV2 {
            self._activeThreadSession = nil
        }

        saveLastActiveThreadId(thread.id)

        do {
            let settings = try await store.loadSettings(forThreadId: thread.id)
            self.activeThreadSettings = settings

            if let providerId = settings.activeProviderId,
               let provider = providers.first(where: { $0.id == providerId }) {
                await switchProvider(provider, modelName: settings.activeModelName)
            } else if let provStore = providerStore,
                      let defaultProvider = try? await provStore.loadDefaultProvider() {
                let modelName = settings.activeModelName.flatMap { name in
                    defaultProvider.models.contains(name) ? name : nil
                } ?? defaultProvider.models.first
                await switchProvider(defaultProvider, modelName: modelName, from: provStore)
            }

            let loaded = try await store.loadMessages(fromThreadId: thread.id, as: ChatMessage.self)
            self.messages = loaded
            resetPagination(fireScrollTrigger: true)

            print("[ChappieViewModel] Thread '\(thread.title)' selected (\(loaded.count) messages)")
        } catch {
            print("[ChappieViewModel] Error loading thread '\(thread.title)': \(error)")
        }

        self.isLoadingThread = false
        self.isAppReady = true

        await loadProjectsForThread(thread)
        buildAndSyncMemoryContext()
        await syncActiveMemoryContext()
        refreshBalanceForActiveProvider()

        // V2: assemble ThreadSession after projects are loaded
        await assembleThreadSession(for: thread)
    }

    // MARK: - Create / Confirm / Cancel

    func createNewThread() {
        guard let store = threadStore else { return }

        Task {
            do {
                let newId = try await store.createThread(title: "Новый тред")
                let refreshed = try await store.loadThreads()
                self.threads = refreshed

                if let newThread = refreshed.first(where: { $0.id == newId }) {
                    if !providers.isEmpty {
                        self.pendingNewThread = newThread
                        self.showNewThreadProviderPicker = true
                    } else {
                        await selectThread(newThread)
                        self.messages = []
                        resetPagination(fireScrollTrigger: false)
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

    func confirmNewThread(with providerId: UUID, modelName: String, title: String, settings: ThreadSettings) async {
        guard let thread = pendingNewThread, let store = threadStore else { return }
        self.pendingNewThread = nil
        self.showNewThreadProviderPicker = false

        if let provider = providers.first(where: { $0.id == providerId }) {
            await switchProvider(provider, modelName: modelName)
        }

        let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalTitle.isEmpty && finalTitle != "Новый тред" {
            try? await store.renameThread(id: thread.id, title: finalTitle)
        }

        var updatedSettings = settings
        updatedSettings.activeProviderId = providerId
        updatedSettings.activeModelName = modelName.isEmpty ? nil : modelName
        try? await store.updateSettings(updatedSettings, forThreadId: thread.id)

        if let refreshed = try? await store.loadThreads() { self.threads = refreshed }

        await selectThread(thread)
        self.messages = []
        resetPagination(fireScrollTrigger: false)
        self.activeProjects = []
        buildAndSyncMemoryContext()
        await syncActiveMemoryContext()
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
                        let newId = try await store.createThread(title: "Новый тред")
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

    // MARK: - Settings Update

    func updateThreadSettings(_ settings: ThreadSettings, newTitle: String, forThreadId threadId: UUID) {
        guard let store = threadStore else { return }

        Task {
            do {
                try await store.renameThread(id: threadId, title: newTitle)

                // Preserve active provider/model — they are managed by switchProvider, not the settings sheet
                var updatedSettings = settings
                if let currentProviderId = activeThreadSettings.activeProviderId {
                    updatedSettings.activeProviderId = currentProviderId
                }
                if let currentModelName = activeThreadSettings.activeModelName {
                    updatedSettings.activeModelName = currentModelName
                }
                try await store.updateSettings(updatedSettings, forThreadId: threadId)

                let refreshed = try await store.loadThreads()
                self.threads = refreshed

                if activeThread?.id == threadId,
                   let updated = refreshed.first(where: { $0.id == threadId }) {
                    self.activeThread = updated
                    self.activeThreadSettings = updatedSettings

                    // V2: settings changed — invalidate cached prompt
                    invalidateActiveThreadSession()
                }
                print("[ChappieViewModel] Thread settings saved for '\(newTitle)'")
            } catch {
                print("[ChappieViewModel] Error updating thread settings: \(error)")
            }
        }
    }
}
