// ChappieViewModel+Providers.swift
// Chappie
//
// Provider and model management: load, switch, reload, user name persistence.
//
// POLICY (provider_model_fallback_policy):
//   NEVER auto-substitute a provider or model on loss.
//   If active provider or model is missing — set orchestrator/aiClient/activeModelName to nil,
//   show orange banner, block send(). User must explicitly choose. No silent fallback.

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

    /// Switches the active provider and model.
    ///
    /// modelName MUST be non-nil and non-empty to create an orchestrator.
    /// Passing nil explicitly blocks the orchestrator — shows the warning banner.
    ///
    /// - Parameter persistSettings: When true (default), writes the new provider/model
    ///   to the active thread's settings in the DB. Pass false when the caller already
    ///   manages persistence (e.g. resolveAndApplyProvider, confirmNewThread) to avoid
    ///   overwriting freshly-loaded or not-yet-saved thread settings with stale data.
    func switchProvider(
        _ provider: AIProvider,
        modelName: String?,
        from store: AIProviderStore? = nil,
        persistSettings: Bool = true
    ) async {
        let provStore = store ?? self.providerStore
        guard let provStore else { return }

        // No model → block orchestrator, show banner. Never fall back to provider.models.first.
        guard let model = modelName, !model.isEmpty else {
            await applyProviderWithoutModel(provider, from: provStore)
            if persistSettings, activeThread != nil {
                var settings = activeThreadSettings
                settings.activeProviderId = provider.id
                settings.activeModelName = nil
                activeThreadSettings = settings
                if let threadId = activeThread?.id, let tStore = threadStore {
                    try? await tStore.updateSettings(settings, forThreadId: threadId)
                }
            }
            return
        }

        let apiKey = await provStore.loadApiKey(for: provider.id) ?? ""
        let client = AIClient(endpoint: provider.endpoint, apiKey: apiKey, modelName: model)
        self.aiClient = client
        self.activeProvider = provider
        self.activeModelName = model
        self.currentBalance = loadBalance(for: provider.id)

        if let ts = toolService, let fs = fileSystem, let mm = memoryManager {
            self.orchestrator = AIOrchestrator(aiClient: client, toolService: ts, fileSystem: fs, memoryManager: mm)
        }

        if persistSettings, activeThread != nil {
            var settings = activeThreadSettings
            settings.activeProviderId = provider.id
            settings.activeModelName = model
            activeThreadSettings = settings
            if let threadId = activeThread?.id, let tStore = threadStore {
                try? await tStore.updateSettings(settings, forThreadId: threadId)
            }
        }

        print("[ChappieViewModel] Switched to provider: \(provider.displayName) / model: \(model)")
    }

    func switchProvider(id: UUID) {
        // No auto-model: pass nil so the user sees the banner and picks explicitly.
        guard let provider = providers.first(where: { $0.id == id }),
              let provStore = providerStore else { return }
        Task { await switchProvider(provider, modelName: nil, from: provStore) }
    }

    func switchModel(to modelName: String) {
        guard let provider = activeProvider, let provStore = providerStore else { return }
        Task { await switchProvider(provider, modelName: modelName, from: provStore) }
    }

    // MARK: - Immediate invalidation (B-04)

    /// Stops any in-flight request and clears aiClient/orchestrator/activeProvider
    /// if the given provider ID matches the currently active one.
    func invalidateProviderIfDeleted(id: UUID) {
        guard activeProvider?.id == id else { return }

        print("[ChappieViewModel] Active provider deleted — invalidating client and orchestrator")
        currentRequestTask?.cancel()
        currentRequestTask = nil

        self.activeProvider = nil
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
        // Keep activeProvider — the provider still exists, only the model is gone.
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
                    } else {
                        // Provider gone — invalidate. No auto-fallback to another provider.
                        print("[ChappieViewModel] Active provider gone after reload — invalidating")
                        self.activeProvider = nil
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
