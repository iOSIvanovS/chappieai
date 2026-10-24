// ChappieViewModel+ThreadProvider.swift
// Chappie
//
// Provider resolution for thread selection: validate saved provider/key/model,
// block orchestrator if anything is missing, apply without model when needed.

import SwiftUI
import ChappieCore

extension ChappieViewModel {

    // MARK: - Provider Resolution

    /// Resolves which provider/key/model to use for a thread.
    ///
    /// POLICY: never auto-substitute. If provider, key, or model is missing — block orchestrator,
    /// show banner. User must pick explicitly.
    func resolveAndApplyProvider(for thread: ThreadMetadata, settings: ThreadSettings) async {
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

                var healed = settings
                if keyMissing { healed.activeKeyId = nil }
                if modelMissing { healed.activeModelName = nil }
                await persistThreadSettings(healed, threadId: thread.id)

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
            var healed = settings
            healed.activeProviderId = nil
            healed.activeKeyId = nil
            healed.activeModelName = nil
            await persistThreadSettings(healed, threadId: thread.id)
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
}
