// ProviderDetailView.swift
// Chappie
//
// Level 2 of ProvidersSettingsView — drill-down into a single provider.
// Shows keys section (hidden for no-auth providers like Ollama) and models section.
// Derived `currentProvider` stays reactive via @Observable on ChappieViewModel.

import SwiftUI
import ChappieCore

// MARK: - ProviderDetailView

struct ProviderDetailView: View {

    let provider: AIProvider
    // Plain var — @Observable tracks viewModel.providers changes automatically.
    var viewModel: ChappieViewModel
    let onBack: () -> Void

    @State var showEditProvider: Bool = false
    @State var showAddKey: Bool = false
    @State var editingKey: APIKey? = nil
    @State var deleteKeyId: UUID? = nil
    @State var showAddModel: Bool = false
    @State var deleteModelId: String? = nil
    @State var errorMessage: String? = nil

    // Derived from viewModel.providers — stays reactive without manual refresh.
    var currentProvider: AIProvider {
        viewModel.providers.first(where: { $0.id == provider.id }) ?? provider
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            HStack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                        Text("providers.back")
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    showEditProvider = true
                } label: {
                    Label("providers.edit", systemImage: "pencil")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            providerInfoCard
                .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Keys section — hidden for providers that don't use API keys (e.g. Ollama)
                    if currentProvider.requiresApiKey {
                        keysSection
                            .padding(.bottom, 8)

                        Divider()
                            .padding(.vertical, 8)
                    }

                    modelsSection
                        .padding(.bottom, 8)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
            }

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
            }
        }
        .sheet(isPresented: $showEditProvider) {
            AddProviderSheet(
                providerStore: viewModel.providerStore,
                editingProvider: currentProvider,
                onSaved: {
                    showEditProvider = false
                    viewModel.reloadProviders()
                },
                onCancel: { showEditProvider = false }
            )
        }
        .sheet(isPresented: $showAddKey) {
            EditKeySheet(
                provider: currentProvider,
                editingKey: nil,
                providerStore: viewModel.providerStore,
                onSaved: {
                    showAddKey = false
                    viewModel.reloadProviders()
                },
                onCancel: { showAddKey = false }
            )
        }
        .sheet(item: $editingKey) { key in
            EditKeySheet(
                provider: currentProvider,
                editingKey: key,
                providerStore: viewModel.providerStore,
                onSaved: {
                    editingKey = nil
                    viewModel.reloadProviders()
                },
                onCancel: { editingKey = nil }
            )
        }
        .sheet(isPresented: $showAddModel) {
            AddModelSheet(
                provider: currentProvider,
                existingModels: currentProvider.models,
                providerStore: viewModel.providerStore,
                remoteService: viewModel.providersRemoteService,
                onSaved: { newModels in
                    showAddModel = false
                    addModels(newModels)
                },
                onCancel: { showAddModel = false }
            )
        }
        .alert("providers.key_delete_title", isPresented: Binding(
            get: { deleteKeyId != nil },
            set: { if !$0 { deleteKeyId = nil } }
        )) {
            Button("providers.key_delete_confirm", role: .destructive) {
                if let id = deleteKeyId { deleteKey(id: id) }
                deleteKeyId = nil
            }
            Button("providers.key_delete_cancel", role: .cancel) { deleteKeyId = nil }
        } message: {
            Text("providers.key_delete_message")
        }
        .alert("providers.model_delete_title", isPresented: Binding(
            get: { deleteModelId != nil },
            set: { if !$0 { deleteModelId = nil } }
        )) {
            Button("providers.model_delete_confirm", role: .destructive) {
                if let id = deleteModelId { deleteModel(id) }
                deleteModelId = nil
            }
            Button("providers.model_delete_cancel", role: .cancel) { deleteModelId = nil }
        } message: {
            Text("providers.model_delete_message")
        }
    }
}
