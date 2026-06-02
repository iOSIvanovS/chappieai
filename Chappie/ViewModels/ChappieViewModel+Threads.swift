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

        // Cancel any in-flight background sync from a previous thread switch.
        // WHY: syncFileSystemForActiveThread() can take 100ms–2s per project (bookmark resolution).
        // Without cancellation, a slow previous sync races with the new one and can leave
        // isFileSystemReady in an inconsistent state (e.g. set to true by the old thread's sync
        // after the new thread's sync already started its own bookmark resolution).
        _syncTask?.cancel()
        _syncTask = nil

        // Instant UI reset — user sees spinner immediately
        self.isLoadingThread = true
        self.messages = []
        self.displayedMessages = []
        self.activeThread = thread

        // V2: discard previous session immediately on thread switch
        if FeatureFlags.useThreadIsolationV2 {
            self._activeThreadSession = nil
        }

        saveLastActiveThreadId(thread.id)

        // Load settings synchronously — single fast SwiftData fetch (~1ms).
        // Settings MUST be ready before we release the spinner so the toolbar
        // shows the correct provider name from frame one.
        let settings = (try? await store.loadSettings(forThreadId: thread.id)) ?? ThreadSettings()
        self.activeThreadSettings = settings

        // Apply provider from in-memory providers[] — zero SwiftData hit.
        // resolveAndApplyProvider reads self.providers which is already cached in RAM.
        await resolveAndApplyProvider(for: thread, settings: settings)

        // Release spinner — user sees the chat (empty for now) immediately.
        // Messages load in the background Task below.
        self.isLoadingThread = false
        self.isAppReady = true

        // Background: load messages + projects + memory + FS.
        // All of this runs after SwiftUI renders the empty chat frame.
        // Stored in _syncTask so a subsequent selectThread() can cancel it immediately.
        _syncTask = Task { [weak self] in
            guard let self else { return }

            // Load messages — the only remaining SwiftData hit on thread switch.
            // Runs in background so the empty chat is visible immediately.
            if let loaded = try? await store.loadMessages(fromThreadId: thread.id, as: ChatMessage.self) {
                guard !Task.isCancelled else { return }
                self.messages = loaded
                self.resetPagination(fireScrollTrigger: true)
                print("[ChappieViewModel] Thread '\(thread.title)' selected (\(loaded.count) messages)")
            }

            guard !Task.isCancelled else { return }
            await self.loadProjectsForThread(thread)

            guard !Task.isCancelled else { return }
            self.buildAndSyncMemoryContext()
            await self.syncActiveMemoryContext()
            self.refreshBalanceForActiveProvider()

            // V2: assemble session + sync FileSystem — slowest part, runs last.
            guard !Task.isCancelled else { return }
            await self.assembleThreadSession(for: thread)
        }
    }

    // MARK: - Provider Resolution (B-03 fix)

    /// Resolves which provider to use for a thread, with healing for orphaned UUIDs.
    ///
    /// WHY NO SwiftData CALLS HERE:
    /// self.providers[] is already loaded into RAM at app start and kept fresh by
    /// loadProvidersAndSetActive / reloadProviders. Reading from it is instant.
    /// provStore.loadDefaultProvider() used to be called here — that was a SwiftData
    /// fetch that could block for seconds if the DB was under write pressure.
    /// Now we resolve the default via providerStore.loadDefaultProvider() which is
    /// served from AIProviderStore's in-memory cache — no DB hit.
    ///
    /// persistSettings: false — settings are already loaded from DB here; we must NOT
    /// let switchProvider overwrite them with stale activeThreadSettings from the previous
    /// thread. Healing writes (Case 2) are done explicitly below with the correct data.
    private func resolveAndApplyProvider(for thread: ThreadMetadata, settings: ThreadSettings) async {
        guard let provStore = providerStore else { return }

        // Case 1: saved UUID matches a known provider — validate model too.
        // WHY: the model may have been deleted since last session. If savedModelName
        // is not in provider.models, treat it as nil so the banner fires and
        // orchestrator is NOT created with a ghost model name.
        if let savedId = settings.activeProviderId,
           let provider = providers.first(where: { $0.id == savedId }) {
            let validatedModel = settings.activeModelName.flatMap {
                provider.models.contains($0) ? $0 : nil
            }
            if validatedModel == nil, settings.activeModelName != nil {
                // Model was deleted — heal the DB record so next restart is clean.
                print("[ChappieViewModel] ⚠️ B-04: Model '\(settings.activeModelName!)' not found in provider '\(provider.displayName)' — healing")
                if let tStore = threadStore {
                    var healed = settings
                    healed.activeModelName = nil
                    try? await tStore.updateSettings(healed, forThreadId: thread.id)
                }
            }
            await switchProvider(provider, modelName: validatedModel, from: provStore, persistSettings: false)
            return
        }

        // Case 2: UUID is set but not found — provider was deleted or recreated.
        // loadDefaultProvider() is served from AIProviderStore's in-memory cache — no DB hit.
        if let orphanedId = settings.activeProviderId {
            print("[ChappieViewModel] ⚠️ B-03: Provider \(orphanedId) not found for thread '\(thread.title)' — healing")

            let resolved = (try? await provStore.loadDefaultProvider()) ?? providers.first

            if let provider = resolved {
                await switchProvider(provider, modelName: settings.activeModelName, from: provStore, persistSettings: false)

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

        // Case 3: no saved provider at all — use cached default (no DB hit).
        if let defaultProvider = (try? await provStore.loadDefaultProvider()) ?? providers.first {
            let modelName = settings.activeModelName.flatMap { name in
                defaultProvider.models.contains(name) ? name : nil
            } ?? defaultProvider.models.first
            await switchProvider(defaultProvider, modelName: modelName, from: provStore, persistSettings: false)
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

        // persistSettings: false — we write the complete settings record explicitly below,
        // so switchProvider must not overwrite it with potentially stale activeThreadSettings.
        if let provider = providers.first(where: { $0.id == providerId }) {
            await switchProvider(provider, modelName: modelName, persistSettings: false)
        }

        // Always rename — even if title is "Новый тред" (user may have typed it explicitly).
        let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = finalTitle.isEmpty ? "Новый тред" : finalTitle
        try? await store.renameThread(id: thread.id, title: resolvedTitle)

        var updatedSettings = settings
        updatedSettings.activeProviderId = providerId
        updatedSettings.activeModelName = modelName.isEmpty ? nil : modelName
        try? await store.updateSettings(updatedSettings, forThreadId: thread.id)

        // Reload threads so we pass the up-to-date ThreadMetadata (with correct title) to selectThread.
        // WHY: thread object captured in pendingNewThread still has the old title "Новый тред".
        let refreshed = (try? await store.loadThreads()) ?? []
        self.threads = refreshed
        let updatedThread = refreshed.first(where: { $0.id == thread.id }) ?? thread

        await selectThread(updatedThread)
        self.messages = []
        resetPagination(fireScrollTrigger: false)
        self.activeProjects = []
        buildAndSyncMemoryContext()
        await syncActiveMemoryContext()

        // Send live AI greeting as the first message in the new thread.
        // Runs in background — thread opens immediately, greeting arrives shortly after.
        Task { [weak self] in
            await self?.sendWelcomeGreeting(for: updatedThread)
        }
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

    // MARK: - Welcome Greeting

    /// Requests a short AI greeting and saves it as the first message in the thread.
    ///
    /// WHY SEPARATE METHOD:
    /// Keeps confirmNewThread() readable. Greeting is best-effort — any failure is silent.
    /// appLanguage is hardcoded "ru" for now; wire AppSettings.appLanguage when i18n lands.
    private func sendWelcomeGreeting(for thread: ThreadMetadata) async {
        guard let client = aiClient, let store = threadStore else { return }

        // TODO: replace "ru" with AppSettings.appLanguage when i18n lands.
        let appLanguage: String? = "ru"

        guard let greetingText = await WelcomeService.generateGreeting(
            using: client,
            appLanguage: appLanguage
        ) else { return }

        let greetingMessage = ChatMessage.message(isUser: false, text: greetingText)

        // Only add if thread is still active and still empty — user may have typed already.
        guard activeThread?.id == thread.id, messages.isEmpty else { return }

        messages.append(greetingMessage)
        appendToDisplayed(greetingMessage)

        // Persist so greeting survives app restart.
        try? await store.saveMessages(messages, toThreadId: thread.id)
        print("[ChappieViewModel] Welcome greeting saved for thread '\(thread.title)'")
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

                // M-08: apply new provider/model if user changed them.
                // persistSettings: false — we write the complete record explicitly below.
                if let providerId = newProviderId,
                   let provider = providers.first(where: { $0.id == providerId }) {
                    let modelName = newModelName ?? provider.models.first
                    await switchProvider(provider, modelName: modelName, persistSettings: false)
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
