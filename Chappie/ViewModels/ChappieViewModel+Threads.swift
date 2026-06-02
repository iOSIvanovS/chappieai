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
            // PARALLEL LOAD: settings and messages are independent — fetch simultaneously.
            // WHY: sequential await adds ~100-300ms per call; on cold switch this stacks up.
            // NOTE: ChatMessage.self cannot be passed in nonisolated async let (Swift 6 actor
            // isolation constraint). We use a MainActor Task pair instead.
            async let settingsTask = store.loadSettings(forThreadId: thread.id)

            // loadMessages is called after settingsTask to avoid the nonisolated ChatMessage.self
            // constraint in async let. Settings are fast (single record) — the sequential cost is minimal.
            let settings = try await settingsTask

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

        // UI is unblocked here — user sees messages immediately.
        self.isLoadingThread = false
        self.isAppReady = true

        // These run after UI is shown — background work, non-blocking for the user.
        // loadProjectsForThread + memory context are fast (SwiftData fetch).
        // syncFileSystemForActiveThread is slow (bookmark resolution) — runs last,
        // protected by isFileSystemReady flag in ToolExecutionService.
        await loadProjectsForThread(thread)
        buildAndSyncMemoryContext()
        await syncActiveMemoryContext()
        refreshBalanceForActiveProvider()

        // V2: assemble session + sync FileSystem in background after UI is shown.
        // isFileSystemReady is set false before sync, true after — file tools are
        // blocked during the window to prevent stale FS responses.
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

    /// Called from ThreadSettingsSheet on save.
    /// - Parameters:
    ///   - settings: Updated context/unlimited settings.
    ///   - newTitle: Renamed thread title.
    ///   - threadId: Target thread ID.
    ///   - newProviderId: Non-nil when user changed the provider in M-08 picker.
    ///   - newModelName: Non-nil when user changed the model in M-08 picker.
    func updateThreadSettings(
        _ settings: ThreadSettings,
        newTitle: String,
        forThreadId threadId: UUID,
        newProviderId: UUID? = nil,
        newModelName: String? = nil
    ) {
        guard let store = threadStore else { return }

        Task {
            do {
                try await store.renameThread(id: threadId, title: newTitle)

                var updatedSettings = settings

                // M-08: apply new provider/model if user changed them
                if let providerId = newProviderId,
                   let provider = providers.first(where: { $0.id == providerId }) {
                    let modelName = newModelName ?? provider.models.first
                    await switchProvider(provider, modelName: modelName)
                    updatedSettings.activeProviderId = providerId
                    updatedSettings.activeModelName = modelName?.isEmpty == false ? modelName : nil
                } else {
                    // Preserve existing provider/model — managed by switchProvider, not overwritten here
                    updatedSettings.activeProviderId = activeThreadSettings.activeProviderId
                    updatedSettings.activeModelName = activeThreadSettings.activeModelName
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
