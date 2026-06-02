// ChappieViewModel+Providers.swift
// Chappie
//
// Provider and model management: load, switch, reload, user name persistence.

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
    /// - Parameter persistSettings: When true (default), writes the new provider/model
    ///   to the active thread's settings in the DB. Pass false when the caller already
    ///   manages persistence (e.g. resolveAndApplyProvider, confirmNewThread) to avoid
    ///   overwriting freshly-loaded or not-yet-saved thread settings with stale data.
    ///
    /// WHY THIS FLAG EXISTS (B-03):
    /// switchProvider was always persisting to activeThread, but during selectThread()
    /// it was called BEFORE activeThreadSettings was fully loaded — so it wrote stale
    /// settings from the PREVIOUS thread into the NEW thread's DB record.
    /// After several thread switches all threads ended up with each other's providers.
    func switchProvider(
        _ provider: AIProvider,
        modelName: String?,
        from store: AIProviderStore? = nil,
        persistSettings: Bool = true
    ) async {
        let provStore = store ?? self.providerStore
        guard let provStore else { return }

        let apiKey = await provStore.loadApiKey(for: provider.id) ?? ""
        let model = modelName ?? provider.models.first ?? ""
        let client = AIClient(endpoint: provider.endpoint, apiKey: apiKey, modelName: model)
        self.aiClient = client
        self.activeProvider = provider
        self.activeModelName = model.isEmpty ? nil : model
        self.currentBalance = loadBalance(for: provider.id)

        if let ts = toolService, let fs = fileSystem, let mm = memoryManager {
            self.orchestrator = AIOrchestrator(aiClient: client, toolService: ts, fileSystem: fs, memoryManager: mm)
        }

        // Only persist when the caller explicitly wants it.
        // During thread load (resolveAndApplyProvider) — skip: settings are already
        // loaded from DB and will be written by the caller if healing is needed.
        if persistSettings, activeThread != nil {
            var settings = activeThreadSettings
            settings.activeProviderId = provider.id
            settings.activeModelName = model.isEmpty ? nil : model
            activeThreadSettings = settings
            if let threadId = activeThread?.id, let tStore = threadStore {
                try? await tStore.updateSettings(settings, forThreadId: threadId)
            }
        }

        print("[ChappieViewModel] Switched to provider: \(provider.displayName) / model: \(model)")
    }

    func switchProvider(id: UUID) {
        guard let provider = providers.first(where: { $0.id == id }),
              let provStore = providerStore else { return }
        Task { await switchProvider(provider, modelName: provider.models.first, from: provStore) }
    }

    func switchModel(to modelName: String) {
        guard let provider = activeProvider, let provStore = providerStore else { return }
        Task { await switchProvider(provider, modelName: modelName, from: provStore) }
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
                        // Provider still exists — refresh the local copy.
                        self.activeProvider = updated
                    } else {
                        // Active provider was deleted — invalidate everything so send() is blocked.
                        // WHY: aiClient and orchestrator hold a stale API key/endpoint and will
                        // keep sending requests to the deleted provider if not cleared here.
                        // send() already guards on activeProvider != nil → shows an error to the user.
                        print("[ChappieViewModel] Active provider was deleted — invalidating aiClient and orchestrator")
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
            // MemoryStore not ready yet — retry after 1 second
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
