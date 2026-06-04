// ChappieViewModel+Providers.swift
// Chappie
//
// Provider and model management: load, switch, reload, user name persistence.
//
// POLICY (provider_model_fallback_policy):
//   NEVER auto-substitute a provider or model on loss.
//   If active provider or model is missing — set orchestrator/aiClient/activeModelName to nil,
//   show orange banner, block send(). User must explicitly choose. No silent fallback.
//
// CLIENT CREATION:
//   AIClientFactory.make(for:apiKey:model:) picks the right client implementation
//   based on model.providerProtocol (OpenAI → AIClient, Anthropic → AnthropicClient).
//   Call sites never instantiate clients directly.
//
// MULTI-KEY SCHEMA:
//   Each provider has a list of APIKey entries. Thread settings store activeKeyId.
//   switchProvider() resolves the key secret from Keychain using activeKeyId.
//   If activeKeyId is nil and provider requiresApiKey — orchestrator is blocked, banner shown.
//   If provider does NOT require a key (e.g. Ollama) — keyId nil is valid, empty string used.
//
// THREADS IN-MEMORY SYNC:
//   self.threads is ALWAYS updated after switchProvider, regardless of persistSettings.
//   This ensures ThreadSettingsSheet always receives fresh data when opened.
//   persistSettings only controls whether changes are written to SwiftData.

import SwiftUI
import ChappieCore

extension ChappieViewModel {

    // MARK: - Load

    func loadProvidersAndSetActive(from store: AIProviderStore) async {
        do {
            let loaded = try await store.loadProviders()
            self.providers = loaded
            print("[ChappieViewModel] Loaded \(loaded.count) providers")
        } catch {
            print("[ChappieViewModel] Failed to load providers: \(error)")
        }
    }

    // MARK: - Switch Provider / Model

    /// Switches the active provider, key, and model for the current thread.
    ///
    /// For providers that don't require an API key (e.g. Ollama), keyId may be nil
    /// and an empty string is passed to the client factory — which is valid for local providers.
    ///
    /// - Parameter persistSettings: When true (default), writes the new provider/key/model
    ///   to the active thread's settings in SwiftData.
    ///   Regardless of this flag, self.threads is ALWAYS updated in-memory so
    ///   ThreadSettingsSheet always gets fresh data when opened.
    func switchProvider(
        _ provider: AIProvider,
        keyId: UUID?,
        modelName: String?,
        from store: AIProviderStore? = nil,
        persistSettings: Bool = true
    ) async {
        let provStore = store ?? self.providerStore
        guard let provStore else { return }

        // Always use the freshest provider from in-memory list to avoid stale model list
        let freshProvider = providers.first(where: { $0.id == provider.id }) ?? provider
        print("[ChappieViewModel] switchProvider: '\(freshProvider.displayName)' requiresApiKey=\(freshProvider.requiresApiKey) modelName=\(modelName ?? "nil") models=\(freshProvider.models.map(\.id))")

        guard let modelId = modelName, !modelId.isEmpty,
              let model = freshProvider.models.first(where: { $0.id == modelId }) else {
            print("[ChappieViewModel] switchProvider: model '\(modelName ?? "nil")' not found in provider '\(freshProvider.displayName)' — blocking orchestrator")
            await applyProviderWithoutModel(freshProvider, from: provStore)
            if let threadId = activeThread?.id {
                var settings = activeThreadSettings
                settings.activeProviderId = freshProvider.id
                settings.activeKeyId = keyId
                settings.activeModelName = modelName?.isEmpty == false ? modelName : nil
                activeThreadSettings = settings
                // Always sync in-memory threads so sheet gets fresh data
                updateThreadInMemory(threadId: threadId, settings: settings)
                if persistSettings, let tStore = threadStore {
                    try? await tStore.updateSettings(settings, forThreadId: threadId)
                }
            }
            return
        }

        // Resolve API key — required only if provider.requiresApiKey
        let apiKey: String
        if freshProvider.requiresApiKey {
            guard let resolvedKeyId = keyId,
                  let loadedKey = await provStore.loadApiKey(for: resolvedKeyId),
                  !loadedKey.isEmpty else {
                await applyProviderWithoutModel(freshProvider, from: provStore)
                if let threadId = activeThread?.id {
                    var settings = activeThreadSettings
                    settings.activeProviderId = freshProvider.id
                    settings.activeKeyId = keyId
                    settings.activeModelName = modelId
                    activeThreadSettings = settings
                    // Always sync in-memory threads so sheet gets fresh data
                    updateThreadInMemory(threadId: threadId, settings: settings)
                    if persistSettings, let tStore = threadStore {
                        try? await tStore.updateSettings(settings, forThreadId: threadId)
                    }
                }
                return
            }
            apiKey = loadedKey
        } else {
            // Local provider (e.g. Ollama) — no key needed
            apiKey = ""
        }

        // Factory picks AIClient or AnthropicClient based on model.providerProtocol
        let client = AIClientFactory.make(for: freshProvider, apiKey: apiKey, model: model)
        self.aiClient = client
        self.activeProvider = freshProvider
        self.activeKeyId = keyId
        self.activeModelName = modelId
        self.currentBalance = loadBalance(for: freshProvider.id)

        if let ts = toolService, let fs = fileSystem, let mm = memoryManager {
            self.orchestrator = AIOrchestrator(aiClient: client, toolService: ts, fileSystem: fs, memoryManager: mm)
        }

        if let threadId = activeThread?.id {
            var settings = activeThreadSettings
            settings.activeProviderId = freshProvider.id
            settings.activeKeyId = keyId
            settings.activeModelName = modelId
            activeThreadSettings = settings
            // Always sync in-memory threads so sheet gets fresh data
            updateThreadInMemory(threadId: threadId, settings: settings)
            if persistSettings, let tStore = threadStore {
                try? await tStore.updateSettings(settings, forThreadId: threadId)
            }
        }

        print("[ChappieViewModel] Switched → \(freshProvider.displayName) / \(model.providerProtocol) / key: \(keyId?.uuidString ?? "none") / model: \(modelId)")
    }

    /// Updates the thread object in self.threads in-memory after settings change.
    /// Avoids a full loadThreads() round-trip while keeping the array fresh.
    /// Called after every switchProvider — regardless of persistSettings flag.
    func updateThreadInMemory(threadId: UUID, settings: ThreadSettings) {
        guard let idx = threads.firstIndex(where: { $0.id == threadId }) else { return }
        let old = threads[idx]
        threads[idx] = ThreadMetadata(
            id: old.id,
            title: old.title,
            settings: settings,
            projectIds: old.projectIds,
            createdAt: old.createdAt,
            updatedAt: Date()
        )
    }

    func switchProvider(id: UUID) {
        guard let provider = providers.first(where: { $0.id == id }),
              let provStore = providerStore else { return }
        Task { await switchProvider(provider, keyId: nil, modelName: nil, from: provStore) }
    }

    func switchModel(to modelName: String) {
        guard let provider = activeProvider, let provStore = providerStore else { return }
        Task { await switchProvider(provider, keyId: activeKeyId, modelName: modelName, from: provStore) }
    }

    // MARK: - Immediate invalidation

    func invalidateProviderIfDeleted(id: UUID) {
        guard activeProvider?.id == id else { return }
        print("[ChappieViewModel] Active provider deleted — invalidating")
        currentRequestTask?.cancel()
        currentRequestTask = nil
        self.activeProvider = nil
        self.activeKeyId = nil
        self.aiClient = nil
        self.orchestrator = nil
        self.activeModelName = nil
    }

    func invalidateModelIfDeleted(modelId: String, providerId: UUID) {
        guard activeProvider?.id == providerId, activeModelName == modelId else { return }
        print("[ChappieViewModel] Active model '\(modelId)' deleted — invalidating client")
        currentRequestTask?.cancel()
        currentRequestTask = nil
        self.aiClient = nil
        self.orchestrator = nil
        self.activeModelName = nil
    }

    func invalidateKeyIfDeleted(keyId: UUID, providerId: UUID) {
        guard activeProvider?.id == providerId, activeKeyId == keyId else { return }
        print("[ChappieViewModel] Active key deleted — invalidating client")
        currentRequestTask?.cancel()
        currentRequestTask = nil
        self.aiClient = nil
        self.orchestrator = nil
        self.activeKeyId = nil
    }

    // MARK: - Reload

    func reloadProviders() {
        guard let store = providerStore else { return }
        Task {
            do {
                let loaded = try await store.loadProviders()
                self.providers = loaded

                if let active = activeProvider {
                    if let updated = loaded.first(where: { $0.id == active.id }) {
                        self.activeProvider = updated

                        if let keyId = activeKeyId,
                           !updated.keys.contains(where: { $0.id == keyId }) {
                            print("[ChappieViewModel] Active key gone after reload — invalidating")
                            self.aiClient = nil
                            self.orchestrator = nil
                            self.activeKeyId = nil
                        }
                    } else {
                        print("[ChappieViewModel] Active provider gone after reload — invalidating")
                        self.activeProvider = nil
                        self.activeKeyId = nil
                        self.aiClient = nil
                        self.orchestrator = nil
                        self.activeModelName = nil
                    }
                }

                print("[ChappieViewModel] Providers reloaded: \(loaded.count)")
            } catch {
                print("[ChappieViewModel] Failed to reload providers: \(error)")
            }
        }
    }

    // MARK: - User Name

    func saveUserName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let store = memoryStore else {
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.saveUserName(trimmed)
            }
            return
        }

        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\\\"")
        Task {
            do {
                try await store.saveEntry(
                    key: "user_name",
                    type: "fact",
                    jsonString: "{\"name\": \"\(escaped)\"}",
                    scope: "global"
                )
                print("[ChappieViewModel] User name saved: \(trimmed)")
            } catch {
                print("[ChappieViewModel] Failed to load user name: \(error)")
            }
        }
    }

    func loadUserName() async -> String? {
        guard let store = memoryStore else { return nil }
        do {
            guard let json = try await store.readEntry(key: "user_name", scope: "global") else { return nil }
            guard let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let name = obj["name"] else { return nil }
            return name
        } catch {
            print("[ChappieViewModel] Failed to load user name: \(error)")
            return nil
        }
    }
}
