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

    @State private var showEditProvider: Bool = false
    @State private var showAddKey: Bool = false
    @State private var editingKey: APIKey? = nil
    @State private var deleteKeyId: UUID? = nil
    @State private var showAddModel: Bool = false
    @State private var deleteModelId: String? = nil
    @State private var errorMessage: String? = nil

    // Derived from viewModel.providers — stays reactive without manual refresh.
    private var currentProvider: AIProvider {
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

    // MARK: - Provider Info Card

    private var providerInfoCard: some View {
        HStack(spacing: 16) {
            ProviderIconView(
                iconName: currentProvider.iconName,
                iconColor: currentProvider.resolvedIconColor,
                size: 44
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(currentProvider.displayName)
                        .font(.system(size: 15, weight: .semibold))

                    if currentProvider.isFromCatalog {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor.opacity(0.7))
                            .help("providers.catalog_from")
                    }

                    if currentProvider.origin == .custom {
                        Text("Custom")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }

                Text(currentProvider.baseURL)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 24)
    }

    // MARK: - Keys Section

    private var keysSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("providers.keys_section")
                    .font(.headline)
                Text(verbatim: "(\(currentProvider.keys.count))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { showAddKey = true } label: {
                    Label("providers.keys_add", systemImage: "plus")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }

            if currentProvider.keys.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("providers.keys_empty")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .padding(10)
                .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 2) {
                    ForEach(currentProvider.keys) { key in
                        KeyRow(
                            key: key,
                            onEdit: { editingKey = key },
                            onDelete: { deleteKeyId = key.id }
                        )
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Models Section

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("providers.models_section")
                    .font(.headline)
                Text(verbatim: "(\(currentProvider.models.count))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { showAddModel = true } label: {
                    Label("providers.models_add", systemImage: "plus")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }

            if currentProvider.models.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary.opacity(0.4))
                    Text("providers.models_empty")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                VStack(spacing: 2) {
                    ForEach(currentProvider.models) { model in
                        ModelRow(
                            model: model,
                            onDelete: { deleteModelId = model.id }
                        )
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Actions

    private func addModels(_ models: [AIModel]) {
        guard let store = viewModel.providerStore else { return }
        Task {
            do {
                for model in models {
                    try await store.addModel(model, toProviderId: currentProvider.id)
                }
                viewModel.reloadProviders()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteKey(id: UUID) {
        guard let store = viewModel.providerStore else { return }
        viewModel.invalidateKeyIfDeleted(keyId: id, providerId: currentProvider.id)
        Task {
            do {
                try await store.deleteKey(id: id, fromProviderId: currentProvider.id)
                viewModel.reloadProviders()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteModel(_ modelId: String) {
        guard let store = viewModel.providerStore else { return }
        viewModel.invalidateModelIfDeleted(modelId: modelId, providerId: currentProvider.id)
        Task {
            do {
                try await store.deleteModel(id: modelId, fromProviderId: currentProvider.id)
                viewModel.reloadProviders()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
