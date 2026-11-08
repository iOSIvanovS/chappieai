// ThreadSettingsSheet.swift
// Chappie
//
// Sheet for editing per-thread settings.
// Opened from two places: gear icon in ThreadRowView (sidebar) and gear chip in ProjectChipsView.
//
// ARCHITECTURE (DUMB COMPONENT PRINCIPLE):
// Receives ThreadMetadata + available providers, returns via onSave.
// No direct dependency on ViewModel or SwiftData.

import SwiftUI
import ChappieCore

// MARK: - ThreadSettingsSheet

struct ThreadSettingsSheet: View {

    // MARK: - Input

    let thread: ThreadMetadata
    let providers: [AIProvider]
    let onSave: (String, ThreadSettings, UUID?, UUID?, String?) -> Void
    let onDismiss: () -> Void

    // MARK: - Local draft state

    @State var draftTitle: String
    @State var draftSettings: ThreadSettings
    @State var draftKeyId: UUID?

    // MARK: - Active provider (resolved from draftSettings)

    var activeProvider: AIProvider? {
        guard let id = draftSettings.activeProviderId else { return nil }
        return providers.first { $0.id == id }
    }

    // MARK: - Init

    init(
        thread: ThreadMetadata,
        providers: [AIProvider],
        onSave: @escaping (String, ThreadSettings, UUID?, UUID?, String?) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.thread = thread
        self.providers = providers
        self.onSave = onSave
        self.onDismiss = onDismiss
        self._draftTitle = State(initialValue: thread.title)
        self._draftSettings = State(initialValue: thread.settings)
        self._draftKeyId = State(initialValue: thread.settings.activeKeyId)

        print("[ThreadSettingsSheet] init: providerId=\(thread.settings.activeProviderId?.uuidString ?? "nil") keyId=\(thread.settings.activeKeyId?.uuidString ?? "nil") maxMsgs=\(thread.settings.maxMessagesInContext) terminal=\(thread.settings.terminalAccess.rawValue)")
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    nameSection
                    Divider().padding(.vertical, 2)
                    if let provider = activeProvider, provider.requiresApiKey {
                        keySection(provider: provider)
                        Divider().padding(.vertical, 2)
                    }
                    contextSection
                    Divider().padding(.vertical, 2)
                    terminalSection
                    Divider().padding(.vertical, 2)
                    CurlHostsEditor(enabled: $draftSettings.curlEnabled, hosts: $draftSettings.curlHosts)
                }
                .padding(20)
            }

            Divider()
            footerView
        }
        .frame(width: 480)
        .frame(minHeight: 360)
    }
}

// MARK: - Preview

#Preview("Default settings") {
    ThreadSettingsSheet(
        thread: ThreadMetadata(
            id: UUID(),
            title: "Chappie Development",
            settings: ThreadSettings(),
            createdAt: Date(),
            updatedAt: Date()
        ),
        providers: [],
        onSave: { title, settings, _, _, _ in
            print("Save: \(title)")
        },
        onDismiss: {}
    )
}

#Preview("Terminal — confirm") {
    ThreadSettingsSheet(
        thread: ThreadMetadata(
            id: UUID(),
            title: "Server Ops",
            settings: ThreadSettings(terminalAccess: .confirm),
            createdAt: Date(),
            updatedAt: Date()
        ),
        providers: [],
        onSave: { title, settings, _, _, _ in
            print("Save: \(title), terminal: \(settings.terminalAccess.rawValue)")
        },
        onDismiss: {}
    )
}
