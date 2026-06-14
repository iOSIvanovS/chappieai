// ChappieViewModel+Threads.swift
// Chappie
//
// Thread lifecycle: load, select, create, confirm, cancel, delete, rename, settings update.

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

            // Step 1: load messages from SwiftData.
            if let loaded = try? await store.loadMessages(fromThreadId: thread.id, as: ChatMessage.self) {
                guard !Task.isCancelled else { return }
                self.messages = loaded
                self.resetPagination(fireScrollTrigger: true)
                print("[ChappieViewModel] Thread '\(thread.title)' selected (\(loaded.count) messages)")
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

    // MARK: - Provider Resolution

    /// Resolves which provider/key/model to use for a thread.
    ///
    /// POLICY: never auto-substitute. If provider, key, or model is missing — block orchestrator,
    /// show banner. User must pick explicitly.
    private func resolveAndApplyProvider(for thread: ThreadMetadata, settings: ThreadSettings) async {
        guard let provStore = providerStore else { return }

        if let savedId = settings.activeProviderId,
           let provider = providers.first(where: { $0.id == savedId }) {

            let savedKeyId = settings.activeKeyId
            let savedModelName = settings.activeModelName

            // For keyless providers (e.g. Ollama) — key validation is skipped entirely.
            let requiresKey = provider.requiresApiKey

            // Validate key still exists on provider (only if key is required)
            let actualKeyId: UUID?
            if requiresKey {
                actualKeyId = savedKeyId.flatMap { id in
                    provider.keys.contains(where: { $0.id == id }) ? id : nil
                }
            } else {
                actualKeyId = nil
            }

            // Validate model still exists in provider's model list (by id)
            let validatedModel = savedModelName.flatMap { name in
                provider.models.contains(where: { $0.id == name }) ? name : nil
            }

            // Block orchestrator only if key is required but missing, or model is missing
            let keyMissing = requiresKey && savedKeyId != nil && actualKeyId == nil
            let modelMissing = savedModelName != nil && validatedModel == nil

            if keyMissing || modelMissing {
                let reason = keyMissing ? "Key" : "Model"
                print("[ChappieViewModel] ⚠️ \(reason) missing for provider '\(provider.displayName)' — blocking orchestrator")

                if let tStore = threadStore {
                    var healed = settings
                    if keyMissing { healed.activeKeyId = nil }
                    if modelMissing { healed.activeModelName = nil }
                    try? await tStore.updateSettings(healed, forThreadId: thread.id)
                }

                await applyProviderWithoutModel(provider, from: provStore)
                return
            }

            // All valid — apply
            await switchProvider(
                provider,
                keyId: requiresKey ? (actualKeyId ?? savedKeyId) : nil,
                modelName: validatedModel,
                from: provStore,
                persistSettings: false
            )
            return
        }

        // Saved provider UUID not found (deleted)
        if let orphanedId = settings.activeProviderId {
            print("[ChappieViewModel] ⚠️ Provider \(orphanedId) not found for thread '\(thread.title)' — showing banner")
            self.activeProvider = nil
            self.activeKeyId = nil
            self.aiClient = nil
            self.orchestrator = nil
            self.activeModelName = nil
            if let tStore = threadStore {
                var healed = settings
                healed.activeProviderId = nil
                healed.activeKeyId = nil
                healed.activeModelName = nil
                try? await tStore.updateSettings(healed, forThreadId: thread.id)
            }
            return
        }

        // Brand-new thread with no provider saved yet
        print("[ChappieViewModel] No saved provider for thread '\(thread.title)' — showing banner")
        self.activeProvider = nil
        self.activeKeyId = nil
        self.aiClient = nil
        self.orchestrator = nil
        self.activeModelName = nil
    }

    /// Sets activeProvider without creating aiClient or orchestrator.
    /// Used when key or model is missing — toolbar shows warning banner, send() is blocked.
    func applyProviderWithoutModel(_ provider: AIProvider, from store: AIProviderStore) async {
        self.activeProvider = provider
        self.activeModelName = nil
        self.activeKeyId = nil
        self.aiClient = nil
        self.orchestrator = nil
        self.currentBalance = loadBalance(for: provider.id)
        print("[ChappieViewModel] Applied provider '\(provider.displayName)' with no key/model — orchestrator blocked")
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
        // so it is never overwritten by the empty array returned from SwiftData.
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

    // MARK: - Welcome Greeting

    /// Inserts a static localized greeting as the first assistant message.
    ///
    /// WHY STATIC: AI-generated greetings cause 5–10 s delays on slow models (Gemini
    /// spends time "thinking" even on a trivial prompt). A static string is instant,
    /// deterministic, and fully localized — no network round-trip needed.
    ///
    /// WHY CALLED FROM _syncTask: must run after loadMessages() sets self.messages = loaded,
    /// otherwise the loaded empty array would overwrite the greeting.
    private func insertStaticWelcomeGreeting(for thread: ThreadMetadata) async {
        guard let store = threadStore else { return }
        guard activeThread?.id == thread.id, messages.isEmpty else { return }

        let greeting = Self.localizedWelcomeGreeting()
        let greetingMessage = ChatMessage.message(isUser: false, text: greeting)

        messages.append(greetingMessage)
        appendToDisplayed(greetingMessage)

        try? await store.saveMessages(messages, toThreadId: thread.id)
        print("[ChappieViewModel] Static welcome greeting inserted for thread '\(thread.title)'")
    }

    /// Returns a greeting string for the current device language.
    /// Falls back to English for any unsupported language code.
    static func localizedWelcomeGreeting() -> String {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let greetings: [String: String] = [
            "en": "Hi! I'm your AI assistant. How can I help you today?",
            "ru": "Привет! Я ваш AI-ассистент. Чем могу помочь?",
            "de": "Hallo! Ich bin Ihr KI-Assistent. Wie kann ich Ihnen helfen?",
            "fr": "Bonjour ! Je suis votre assistant IA. Comment puis-je vous aider ?",
            "es": "¡Hola! Soy tu asistente de IA. ¿En qué puedo ayudarte?",
            "pt": "Olá! Sou seu assistente de IA. Como posso ajudar?",
            "ar": "مرحباً! أنا مساعدك الذكي. كيف يمكنني مساعدتك؟",
            "zh": "你好！我是你的 AI 助手。有什么我可以帮你的吗？",
            "ja": "こんにちは！AIアシスタントです。何かお手伝いできますか？",
            "hi": "नमस्ते! मैं आपका AI सहायक हूँ। मैं आपकी कैसे मदद कर सकता हूँ?"
        ]
        return greetings[lang] ?? greetings["en"]!
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

    // MARK: - Settings Update

    /// Saves updated thread settings from ThreadSettingsSheet.
    ///
    /// The sheet owns the full ThreadSettings draft — we trust it completely.
    /// Provider and model are preserved from activeThreadSettings (sheet doesn't change them).
    /// Key change triggers immediate AI client re-init for the active thread.
    func updateThreadSettings(
        _ settings: ThreadSettings,
        newTitle: String,
        forThreadId threadId: UUID,
        newProviderId: UUID? = nil,
        newKeyId: UUID? = nil,
        newModelName: String? = nil
    ) {
        guard let store = threadStore else { return }

        Task {
            do {
                try await store.renameThread(id: threadId, title: newTitle)

                // Start from the sheet's draft — it already has correct maxMessagesInContext,
                // isUnlimitedContext, and activeKeyId set by the sheet's footerView.
                var updatedSettings = settings

                print("[ChappieViewModel] updateThreadSettings: incoming maxMsgs=\(settings.maxMessagesInContext) keyId=\(settings.activeKeyId?.uuidString ?? "nil") providerId=\(settings.activeProviderId?.uuidString ?? "nil")")
                print("[ChappieViewModel] updateThreadSettings: activeThreadSettings providerId=\(activeThreadSettings.activeProviderId?.uuidString ?? "nil") model=\(activeThreadSettings.activeModelName ?? "nil") keyId=\(activeThreadSettings.activeKeyId?.uuidString ?? "nil")")

                if let providerId = newProviderId,
                   let provider = providers.first(where: { $0.id == providerId }) {
                    // Provider explicitly changed — full switch
                    let model = newModelName.flatMap { $0.isEmpty ? nil : $0 }
                    await switchProvider(provider, keyId: newKeyId, modelName: model, persistSettings: false)
                    updatedSettings.activeProviderId = providerId
                    updatedSettings.activeKeyId = newKeyId
                    updatedSettings.activeModelName = model
                } else {
                    // Provider unchanged — preserve provider+model from current active settings.
                    // Key comes from the sheet (already set in settings.activeKeyId by footerView).
                    updatedSettings.activeProviderId = activeThreadSettings.activeProviderId
                    updatedSettings.activeModelName = activeThreadSettings.activeModelName

                    print("[ChappieViewModel] updateThreadSettings: after merge maxMsgs=\(updatedSettings.maxMessagesInContext) keyId=\(updatedSettings.activeKeyId?.uuidString ?? "nil") providerId=\(updatedSettings.activeProviderId?.uuidString ?? "nil")")

                    // If key changed for the active thread — re-init AI client immediately
                    if threadId == activeThread?.id,
                       updatedSettings.activeKeyId != activeKeyId,
                       let provider = activeProvider {
                        print("[ChappieViewModel] updateThreadSettings: key changed → re-init AI client with keyId=\(updatedSettings.activeKeyId?.uuidString ?? "nil")")
                        await switchProvider(
                            provider,
                            keyId: updatedSettings.activeKeyId,
                            modelName: activeModelName,
                            persistSettings: false
                        )
                    }
                }

                try await store.updateSettings(updatedSettings, forThreadId: threadId)
                print("[ChappieViewModel] updateThreadSettings: saved maxMsgs=\(updatedSettings.maxMessagesInContext) keyId=\(updatedSettings.activeKeyId?.uuidString ?? "nil")")

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
