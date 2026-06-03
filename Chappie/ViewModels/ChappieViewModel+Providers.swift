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
// MULTI-KEY SCHEMA:
//   Each provider has a list of APIKey entries. Thread settings store activeKeyId.
//   switchProvider() resolves the key secret from Keychain using activeKeyId.
//   If activeKeyId is nil or key not found — orchestrator is blocked, banner shown.

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
    /// Both keyId and modelName MUST be non-nil to create an orchestrator.
    /// Missing either → blocks orchestrator and shows warning banner.
    ///
    /// - Parameter persistSettings: When true (default), writes the new provider/key/model
    ///   to the active thread's settings in the DB. Pass false when the caller already
    ///   manages persistence to avoid overwriting freshly-loaded settings.
    func switchProvider(
        _ provider: AIProvider,
        keyId: UUID?,
        modelName: String?,
        from store: AIProviderStore? = nil,
        persistSettings: Bool = true
    ) async {
        let provStore = store ?? self.providerStore
        guard let provStore else { return }

        // Both key and model required — block orchestrator if either is missing
        guard let resolvedKeyId = keyId,
              let model = modelName, !model.isEmpty,
              let apiKey = await provStore.loadApiKey(for: resolvedKeyId),
              !apiKey.isEmpty else {
            await applyProviderWithoutModel(provider, from: provStore)
            if persistSettings, activeThread != nil {
                var settings = activeThreadSettings
                settings.activeProviderId = provider.id
                settings.activeKeyId = keyId
                settings.activeModelName = modelName?.isEmpty == false ? modelName : nil
                activeThreadSettings = settings
                if let threadId = activeThread?.id, let tStore = threadStore {
                    try? await tStore.updateSettings(settings, forThreadId: threadId)
                }
            }
            return
        }

        let client = AIClient(endpoint: provider.endpoint, apiKey: apiKey, modelName: model)
        self.aiClient = client
        self.activeProvider = provider
        self.activeKeyId = resolvedKeyId
        self.activeModelName = model
        self.currentBalance = loadBalance(for: provider.id)

        if let ts = toolService, let fs = fileSystem, let mm = memoryManager {
            self.orchestrator = AIOrchestrator(aiClient: client, toolService: ts, fileSystem: fs, memoryManager: mm)
        }

        if persistSettings, activeThread != nil {
            var settings = activeThreadSettings
            settings.activeProviderId = provider.id
            settings.activeKeyId = resolvedKeyId
            settings.activeModelName = model
            activeThreadSettings = settings
            if let threadId = activeThread?.id, let tStore = threadStore {
                try? await tStore.updateSettings(settings, forThreadId: threadId)
            }
        }

        print("[ChappieViewModel] Switched to provider: \(provider.displayName) / key: \(resolvedKeyId) / model: \(model)")
    }

    func switchProvider(id: UUID) {
        // No auto-key/model: pass nil so the user sees the banner and picks explicitly.
        guard let provider = providers.first(where: { $0.id == id }),
              let provStore = providerStore else { return }
        Task { await switchProvider(provider, keyId: nil, modelName: nil, from: provStore) }
    }

    func switchModel(to modelName: String) {
        guard let provider = activeProvider, let provStore = providerStore else { return }
        Task { await switchProvider(provider, keyId: activeKeyId, modelName: modelName, from: provStore) }
    }

    // MARK: - Immediate invalidation

    /// Stops any in-flight request and clears aiClient/orchestrator/activeProvider
    /// if the given provider ID matches the currently active one.
    func invalidateProviderIfDeleted(id: UUID) {
        guard activeProvider?.id == id else { return }

        print("[ChappieViewModel] Active provider deleted — invalidating client and orchestrator")
        currentRequestTask?.cancel()
        currentRequestTask = nil

        self.activeProvider = nil
        self.activeKeyId = nil
        self.aiClient = nil
        self.orchestrator = nil
        self.activeModelName = nil
    }

    /// Stops any in-flight request and clears aiClient/orchestrator/activeModelName
    /// if the deleted model is currently active on the given provider.
    func invalidateModelIfDeleted(name: String, providerId: UUID) {
        guard activeProvider?.id == providerId,
              activeModelName == name else { return }

        print("[ChappieViewModel] Active model '\(name)' deleted — invalidating client and orchestrator")
        currentRequestTask?.cancel()
        currentRequestTask = nil

        self.aiClient = nil
        self.orchestrator = nil
        self.activeModelName = nil
        // Keep activeProvider and activeKeyId — only the model is gone.
    }

    /// Stops any in-flight request and clears aiClient/orchestrator
    /// if the deleted key is currently active on the given provider.
    func invalidateKeyIfDeleted(keyId: UUID, providerId: UUID) {
        guard activeProvider?.id == providerId,
              activeKeyId == keyId else { return }

        print("[ChappieViewModel] Active key deleted — invalidating client and orchestrator")
        currentRequestTask?.cancel()
        currentRequestTask = nil

        self.aiClient = nil
        self.orchestrator = nil
        self.activeKeyId = nil
        // Keep activeProvider and activeModelName — only the key is gone.
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

                        // Validate activeKeyId is still present on the updated provider
                        if let keyId = activeKeyId,
                           !updated.keys.contains(where: { $0.id == keyId }) {
                            print("[ChappieViewModel] Active key gone after reload — invalidating")
                            self.aiClient = nil
                            self.orchestrator = nil
                            self.activeKeyId = nil
                        }
                    } else {
                        // Provider gone — full invalidation
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
                print("[ChappieViewModel] User name saved to global memory: \(trimmed)")
            } catch {
                print("[ChappieViewModel] Failed to save user name: \(error)")
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
