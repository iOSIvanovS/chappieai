// ChappieViewModel+ThreadSettings.swift
// Chappie
//
// Thread settings update: saves ThreadSettingsSheet changes, re-inits AI client on key change.

import SwiftUI
import ChappieCore

extension ChappieViewModel {

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
                await persistThreadTitle(newTitle, threadId: threadId)

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

                await persistThreadSettings(updatedSettings, threadId: threadId)
                print("[ChappieViewModel] updateThreadSettings: saved maxMsgs=\(updatedSettings.maxMessagesInContext) keyId=\(updatedSettings.activeKeyId?.uuidString ?? "nil")")

                let refreshed = try await store.loadThreads()
                self.threads = refreshed

                if activeThread?.id == threadId,
                   let updated = refreshed.first(where: { $0.id == threadId }) {
                    self.activeThread = updated
                    self.activeThreadSettings = updatedSettings
                    invalidateActiveThreadSession()
                    // Curl-Chappie switch and hosts live in ActiveMemoryContext (read by ToolPolicy and
                    // the tool definitions); without this the new hosts appear only after a thread switch.
                    await syncActiveMemoryContext()
                }
                print("[ChappieViewModel] Thread settings saved for '\(newTitle)'")
            } catch {
                print("[ChappieViewModel] Error updating thread settings: \(error)")
            }
        }
    }
}
