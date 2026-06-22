// NewThreadProviderSheet.swift
// Chappie
//
// Sheet shown when creating a new thread.
//
// LEVEL 1 — Provider selection:
//   List of all configured providers. User picks one.
//   Auto-selects first key if provider has keys.
//
// LEVEL 2 — Model selection:
//   Models saved for the selected provider — user picks one.
//   Manual model input available if list is empty.
//
// LEVEL 3 — Thread setup:
//   Thread name, context depth slider, unlimited context toggle.
//
// KEY POLICY:
//   Key selection moved to ThreadSettingsSheet.
//   Here we auto-select first key of the chosen provider (or nil for keyless providers).
//   canConfirm requires provider + model. Key is auto-resolved.
//
// On confirm → passes (providerId, keyId, modelName, threadTitle, ThreadSettings) to ViewModel.
// On cancel → the pending thread is deleted.

import SwiftUI
import ChappieCore

// MARK: - NewThreadProviderSheet

struct NewThreadProviderSheet: View {

    // MARK: - Input

    let providers: [AIProvider]
    let currentProvider: AIProvider?
    let currentModelName: String?
    let onConfirm: (UUID, UUID?, String, String, ThreadSettings) -> Void
    let onCancel: () -> Void

    // MARK: - State

    @State var selectedProviderId: UUID?
    @State var selectedKeyId: UUID?
    @State var selectedModelName: String = ""
    @State var manualModelInput: String = ""

    @State var threadTitle: String = ""
    @State var draftSettings: ThreadSettings = ThreadSettings()

    // MARK: - Computed

    var selectedProvider: AIProvider? {
        providers.first { $0.id == selectedProviderId }
    }

    private var canConfirm: Bool {
        selectedProviderId != nil && !selectedModelName.isEmpty
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            pickerColumns
                .frame(height: 220)
            Divider()
            settingsScroll
                .frame(height: 220)
            Divider()
            footer
        }
        .frame(width: 480)
        .onAppear { applyInitialSelection() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "plus.bubble")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("new_thread.title")
                    .font(.title2.bold())
                Text("new_thread.subtitle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    // MARK: - Settings Scroll

    private var settingsScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                threadNameSection
                Divider()
                contextSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("new_thread.cancel", action: onCancel)
                .keyboardShortcut(.escape)

            Spacer()

            if let provider = selectedProvider {
                if !selectedModelName.isEmpty {
                    Text(verbatim: "\(provider.displayName) · \(selectedModelName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("new_thread.select_model_hint")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Button {
                guard let id = selectedProviderId, !selectedModelName.isEmpty else { return }
                let title = threadTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalTitle = title.isEmpty ? String(localized: "new_thread.name_placeholder") : title
                onConfirm(id, selectedKeyId, selectedModelName, finalTitle, draftSettings)
            } label: {
                Text("new_thread.start")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canConfirm)
            .keyboardShortcut(.return)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Initial Selection

    private func applyInitialSelection() {
        let preselectedProvider = currentProvider ?? providers.first
        selectedProviderId = preselectedProvider?.id
        if let provider = preselectedProvider {
            selectedKeyId = provider.requiresApiKey ? provider.keys.first?.id : nil
        }
        if let model = currentModelName,
           let provider = preselectedProvider,
           provider.models.contains(where: { $0.id == model }) {
            selectedModelName = model
        }
    }
}

// MARK: - Preview

#Preview {
    NewThreadProviderSheet(
        providers: [
            AIProvider(
                id: UUID(),
                name: "AITunnel",
                baseURL: "https://api.aitunnel.ru/v1",
                keys: [APIKey(name: "Work"), APIKey(name: "Personal")],
                models: [
                    AIModel(id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5"),
                    AIModel(id: "gpt-4o", name: "GPT-4o")
                ]
            )
        ],
        currentProvider: nil,
        currentModelName: nil,
        onConfirm: { _, _, _, title, _ in
            print("Confirm: \(title)")
        },
        onCancel: {}
    )
}
