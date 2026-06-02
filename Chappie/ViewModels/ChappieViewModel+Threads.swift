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
        _syncTask?.cancel()
        _syncTask = nil

        self.isLoadingThread = true
        self.messages = []
        self.displayedMessages = []
        self.activeThread = thread

        if FeatureFlags.useThreadIsolationV2 {
            self._activeThreadSession = nil
        }

        saveLastActiveThreadId(thread.id)

        let settings = (try? await store.loadSettings(forThreadId: thread.id)) ?? ThreadSettings()
        self.activeThreadSettings = settings

        await resolveAndApplyProvider(for: thread, settings: settings)

        self.isLoadingThread = false
        self.isAppReady = true

        _syncTask = Task { [weak self] in
            guard let self else { return }

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

            guard !Task.isCancelled else { return }
            await self.assembleThreadSession(for: thread)
        }
    }

    // MARK: - Provider Resolution

    /// Resolves which provider/model to use for a thread.
    ///
    /// POLICY: never auto-substitute. If provider or model is missing — block orchestrator,
    /// show banner. User must pick explicitly.
    ///
    /// Cases:
    ///   1. Saved provider+model both valid → apply normally.
    ///   2. Saved provider valid, model missing/deleted → block orchestrator, show banner.
    ///   3. Saved provider UUID not found (deleted) → block orchestrator, show banner.
    ///   4. No saved provider → block orchestrator, show banner.
    private func resolveAndApplyProvider(for thread: ThreadMetadata, settings: ThreadSettings) async {
        guard let provStore = providerStore else { return }

        // Case 1 & 2: saved provider UUID found in loaded providers.
        if let savedId = settings.activeProviderId,
           let provider = providers.first(where: { $0.id == savedId }) {

            let savedModelName = settings.activeModelName
            let validatedModel = savedModelName.flatMap {
                provider.models.contains($0) ? $0 : nil
            }

            if savedModelName != nil, validatedModel == nil {
                // Case 2: model was saved but is now deleted.
                print("[ChappieViewModel] ⚠️ B-04: Model '\(savedModelName!)' not found in '\(provider.displayName)' — blocking orchestrator")

                // Heal DB so next restart is also clean.
                if let tStore = threadStore {
                    var healed = settings
                    healed.activeModelName = nil
                    try? await tStore.updateSettings(healed, forThreadId: thread.id)
                }

                await applyProviderWithoutModel(provider, from: provStore)
                return
            }

            // Case 1: both provider and model are valid (or no model was ever saved).
            await switchProvider(provider, modelName: validatedModel, from: provStore, persistSettings: false)
            return
        }

        // Case 3: UUID is set but provider was deleted.
        if let orphanedId = settings.activeProviderId {
            print("[ChappieViewModel] ⚠️ B-03: Provider \(orphanedId) not found for thread '\(thread.title)' — showing banner, user must pick")
            // Clear stale provider reference so banner fires.
            self.activeProvider = nil
            self.aiClient = nil
            self.orchestrator = nil
            self.activeModelName = nil
            // Heal DB — remove orphaned UUID so next restart doesn't repeat this path.
            if let tStore = threadStore {
                var healed = settings
                healed.activeProviderId = nil
                healed.activeModelName = nil
                try? await tStore.updateSettings(healed, forThreadId: thread.id)
            }
            return
        }

        // Case 4: brand-new thread with no provider saved yet — show banner, user picks.
        print("[ChappieViewModel] No saved provider for thread '\(thread.title)' — showing banner")
        self.activeProvider = nil
        self.aiClient = nil
        self.orchestrator = nil
        self.activeModelName = nil
    }

    /// Sets activeProvider without creating aiClient or orchestrator.
    /// Used when the saved model was deleted — toolbar shows the warning banner,
    /// send() is blocked, but provider identity is preserved for the picker.
    func applyProviderWithoutModel(_ provider: AIProvider, from store: AIProviderStore) async {
        self.activeProvider = provider
        self.activeModelName = nil
        self.aiClient = nil
        self.orchestrator = nil
        self.currentBalance = loadBalance(for: provider.id)
        print("[ChappieViewModel] B-04: Applied provider '\(provider.displayName)' with no model — orchestrator blocked")
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
            await switchProvider(provider, modelName: modelName.isEmpty ? nil : modelName, persistSettings: false)
        }

        let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = finalTitle.isEmpty ? "Новый тред" : finalTitle
        try? await store.renameThread(id: thread.id, title: resolvedTitle)

        var updatedSettings = settings
        updatedSettings.activeProviderId = providerId
        updatedSettings.activeModelName = modelName.isEmpty ? nil : modelName
        try? await store.updateSettings(updatedSettings, forThreadId: thread.id)

        let refreshed = (try? await store.loadThreads()) ?? []
        self.threads = refreshed
        let updatedThread = refreshed.first(where: { $0.id == thread.id }) ?? thread

        await selectThread(updatedThread)
        self.messages = []
        resetPagination(fireScrollTrigger: false)
        self.activeProjects = []
        buildAndSyncMemoryContext()
        await syncActiveMemoryContext()

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

    private func sendWelcomeGreeting(for thread: ThreadMetadata) async {
        guard let client = aiClient, let store = threadStore else { return }

        let appLanguage: String? = "ru"

        guard let greetingText = await WelcomeService.generateGreeting(
            using: client,
            appLanguage: appLanguage
        ) else { return }

        let greetingMessage = ChatMessage.message(isUser: false, text: greetingText)

        guard activeThread?.id == thread.id, messages.isEmpty else { return }

        messages.append(greetingMessage)
        appendToDisplayed(greetingMessage)

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

                if let providerId = newProviderId,
                   let provider = providers.first(where: { $0.id == providerId }) {
                    // Use exactly what the user picked — no auto-fallback to models.first.
                    let model = newModelName.flatMap { $0.isEmpty ? nil : $0 }
                    await switchProvider(provider, modelName: model, persistSettings: false)
                    updatedSettings.activeProviderId = providerId
                    updatedSettings.activeModelName = model
                } else {
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
                    invalidateActiveThreadSession()
                }
                print("[ChappieViewModel] Thread settings saved for '\(newTitle)'")
            } catch {
                print("[ChappieViewModel] Error updating thread settings: \(error)")
            }
        }
    }
}
