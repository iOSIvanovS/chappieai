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

            await resolveAndApplyProvider(for: thread, settings: settings)

            let loaded = try await store.loadMessages(fromThreadId: thread.id, as: ChatMessage.self)
            self.messages = loaded
            resetPagination(fireScrollTrigger: true)

            print("[ChappieViewModel] Thread '\(thread.title)' selected (\(loaded.count) messages)")
        } catch {
            print("[ChappieViewModel] Error loading thread '\(thread.title)': \(error)")
        }

        // Unblock UI — user sees messages NOW.
        // WHY: isLoadingThread=false must be followed by a Task{} break so SwiftUI
        // actually gets a chance to re-render before we start the background work below.
        // Without Task{} all the awaits below keep MainActor busy and the screen stays
        // frozen even though the flag is already false.
        self.isLoadingThread = false
        self.isAppReady = true

        // Background post-load: runs after SwiftUI renders the messages.
        // loadProjects + memory context are fast (SwiftData fetch, ~10ms).
        // syncFileSystemForActiveThread is slow (bookmark resolution, up to 2s) —
        // protected by isFileSystemReady flag so file tools are blocked until ready.
        Task { [weak self] in
            guard let self else { return }
            await self.loadProjectsForThread(thread)
            self.buildAndSyncMemoryContext()
            await self.syncActiveMemoryContext()
            self.refreshBalanceForActiveProvider()

            // V2: assemble session + sync FileSystem — slowest part, runs last.
            await self.assembleThreadSession(for: thread)
        }
    }

    // MARK: - Provider Resolution (B-03 fix)

    /// Resolves which provider to use for a thread, with healing for orphaned UUIDs.
    ///
    /// WHY SEPARATE METHOD:
    /// selectThread() was doing inline provider lookup — if UUID wasn't found it silently
    /// fell back to the default provider for every thread, causing the "off-by-one" symptom
    /// where all threads appeared to share the same provider after app restart.
    ///
    /// HEALING: When a saved UUID is orphaned (provider deleted/recreated), we fall back to
    /// the best available provider AND immediately persist the corrected UUID to the thread's
    /// settings. Next app start will find the correct UUID — no more silent fallback.
    private func resolveAndApplyProvider(for thread: ThreadMetadata, settings: ThreadSettings) async {
        guard let provStore = providerStore else { return }

        // Case 1: saved UUID matches a known provider — exact match, happy path.
        if let savedId = settings.activeProviderId,
           let provider = providers.first(where: { $0.id == savedId }) {
            await switchProvider(provider, modelName: settings.activeModelName, from: provStore)
            return
        }

        // Case 2: UUID is set but not found — provider was deleted or recreated.
        // Log a warning, pick the best available provider, and heal the stored UUID.
        if let orphanedId = settings.activeProviderId {
            print("[ChappieViewModel] ⚠️ B-03: Provider \(orphanedId) not found for thread '\(thread.title)' — healing")

            let fallback = try? await provStore.loadDefaultProvider()
            let resolved = fallback ?? providers.first

            if let provider = resolved {
                await switchProvider(provider, modelName: settings.activeModelName, from: provStore)

                // Heal: persist corrected UUID so next restart finds the right provider.
                if let tStore = threadStore {
                    var healed = settings
                    healed.activeProviderId = provider.id
                    healed.activeModelName = settings.activeModelName.flatMap {
                        provider.models.contains($0) ? $0 : nil
                    } ?? provider.models.first
                    try? await tStore.updateSettings(healed, forThreadId: thread.id)
                    print("[ChappieViewModel] ✅ B-03: Healed thread '\(thread.title)' → provider '\(provider.displayName)'")
                }
            } else {
                print("[ChappieViewModel] ⚠️ B-03: No providers available for thread '\(thread.title)'")
            }
            return
        }

        // Case 3: no saved provider at all — use default.
        if let defaultProvider = try? await provStore.loadDefaultProvider() {
            let modelName = settings.activeModelName.flatMap { name in
                defaultProvider.models.contains(name) ? name : nil
            } ?? defaultProvider.models.first
            await switchProvider(defaultProvider, modelName: modelName, from: provStore)
        }
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

        // Always rename — even if title is "Новый тред" (user may have typed it explicitly).
        // Use the thread object from refreshed list after rename so selectThread gets the correct title.
        let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = finalTitle.isEmpty ? "Новый тред" : finalTitle
        try? await store.renameThread(id: thread.id, title: resolvedTitle)

        var updatedSettings = settings
        updatedSettings.activeProviderId = providerId
        updatedSettings.activeModelName = modelName.isEmpty ? nil : modelName
        try? await store.updateSettings(updatedSettings, forThreadId: thread.id)

        // Reload threads so we pass the up-to-date ThreadMetadata (with correct title) to selectThread.
        // WHY: thread object captured in pendingNewThread still has the old title "Новый тред".
        // Passing stale object to selectThread sets activeThread.title incorrectly in the sidebar.
        let refreshed = (try? await store.loadThreads()) ?? []
        self.threads = refreshed
        let updatedThread = refreshed.first(where: { $0.id == thread.id }) ?? thread

        await selectThread(updatedThread)
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
