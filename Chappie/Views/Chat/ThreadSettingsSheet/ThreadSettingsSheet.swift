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
    /// True when the current license plan allows terminal access (not Starter).
    let canExecuteTools: Bool
    /// Called when user taps "Change Plan" in the Starter restriction alert.
    let onChangePlan: () -> Void

    // MARK: - Local draft state

    @State var draftTitle: String
    @State var draftSettings: ThreadSettings
    @State var draftKeyId: UUID?
    @State var showingStarterAlert = false

    // MARK: - Active provider (resolved from draftSettings)

    var activeProvider: AIProvider? {
        guard let id = draftSettings.activeProviderId else { return nil }
        return providers.first { $0.id == id }
    }

    // MARK: - Init

    init(
        thread: ThreadMetadata,
        providers: [AIProvider],
        canExecuteTools: Bool = true,
        onSave: @escaping (String, ThreadSettings, UUID?, UUID?, String?) -> Void,
        onDismiss: @escaping () -> Void,
        onChangePlan: @escaping () -> Void = {}
    ) {
        self.thread = thread
        self.providers = providers
        self.canExecuteTools = canExecuteTools
        self.onSave = onSave
        self.onDismiss = onDismiss
        self.onChangePlan = onChangePlan
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
        .alert("thread.settings.starter_terminal_alert_title", isPresented: $showingStarterAlert) {
            Button("thread.settings.starter_terminal_alert_cancel", role: .cancel) {}
            Button("thread.settings.starter_terminal_alert_change_plan") {
                onDismiss()
                onChangePlan()
            }
        } message: {
            Text("thread.settings.starter_terminal_alert_message")
        }
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
