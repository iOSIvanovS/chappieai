// ProvidersSettingsView.swift
// Chappie
//
// Two-level directory view for AI providers.
// This is a READ/MANAGE view — no active provider selection happens here.
// Selection of provider+key+model happens at the thread level.
//
// LEVEL 1 — Provider list:
//   Shows all configured providers. Tap → drill into provider detail.
//   "Добавить провайдера" → opens CatalogPickerSheet (catalog list + custom option).
//
// LEVEL 2 — Provider detail (ProviderDetailView):
//   Keys section: list of named API keys with add/edit/delete.
//   Models section: list of saved models with add (via AddModelSheet) / delete.
//   Edit provider metadata (name, endpoint) via AddProviderSheet (edit mode).
//
// NAVIGATION:
//   Uses if/else state switch instead of NavigationStack — NavigationStack
//   inside a sheet on macOS does not behave as drill-down, it creates a full
//   navigation window which breaks the sheet layout.
//
// ORPHANED THREADS:
//   Deleting a provider, key, or model is always allowed.
//   Affected threads show a warning banner in the chat view.

import SwiftUI
import ChappieCore

// MARK: - ProvidersSettingsView

struct ProvidersSettingsView: View {

    // MARK: - Dependencies

    var viewModel: ChappieViewModel

    // MARK: - State

    @State private var showAddProvider: Bool = false
    @State private var selectedProvider: AIProvider? = nil
    @State private var deleteConfirmId: UUID? = nil
    @State private var errorMessage: String? = nil

    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        Group {
            if let provider = selectedProvider {
                ProviderDetailView(
                    provider: provider,
                    viewModel: viewModel,
                    onBack: { selectedProvider = nil }
                )
            } else {
                providerListView
            }
        }
        .frame(width: 560, height: 480)
        // Opens catalog picker → which then opens AddProviderSheet internally
        .sheet(isPresented: $showAddProvider) {
            CatalogPickerSheet(
                providerStore: viewModel.providerStore,
                remoteService: viewModel.providersRemoteService,
                onSaved: {
                    viewModel.reloadProviders()
                    showAddProvider = false
                },
                onCancel: { showAddProvider = false }
            )
        }
        .alert("Удалить провайдера?", isPresented: Binding(
            get: { deleteConfirmId != nil },
            set: { if !$0 { deleteConfirmId = nil } }
        )) {
            Button("Удалить", role: .destructive) {
                if let id = deleteConfirmId { deleteProvider(id: id) }
                deleteConfirmId = nil
            }
            Button("Отмена", role: .cancel) { deleteConfirmId = nil }
        } message: {
            Text("Провайдер и все его ключи будут удалены. Треды, использующие этого провайдера, покажут предупреждение.")
        }
    }

    // MARK: - Provider List View

    private var providerListView: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {
                Image(systemName: "cpu")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("AI-провайдеры")
                    .font(.title2.bold())
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 20)

            Divider()

            if viewModel.providers.isEmpty {
                emptyState
            } else {
                providerList
            }

            Divider()

            // Footer
            HStack {
                Button {
                    showAddProvider = true
                } label: {
                    Label("Добавить провайдера", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                if let err = errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }

                Button("Закрыть") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Provider List

    private var providerList: some View {
        List {
            ForEach(viewModel.providers) { provider in
                ProviderListRow(
                    provider: provider,
                    onTap: { selectedProvider = provider },
                    onDelete: { deleteConfirmId = provider.id }
                )
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "cpu.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary.opacity(0.4))
            Text("Нет настроенных провайдеров")
                .font(.title3.bold())
                .foregroundStyle(.secondary)
            Text("Добавьте AI-провайдера чтобы начать работу")
                .font(.subheadline)
                .foregroundStyle(.secondary.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func deleteProvider(id: UUID) {
        guard let store = viewModel.providerStore else { return }

        // Synchronously clear aiClient/orchestrator BEFORE the async delete.
        // WHY: reloadProviders() spawns a Task — there is a race window where
        // send() can fire and find a non-nil orchestrator pointing at the deleted provider.
        viewModel.invalidateProviderIfDeleted(id: id)

        Task {
            do {
                try await store.deleteProvider(id: id)
                viewModel.reloadProviders()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - ProviderListRow

private struct ProviderListRow: View {

    let provider: AIProvider
    let onTap: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {

            VStack(alignment: .leading, spacing: 3) {
                Text(provider.displayName)
                    .font(.system(size: 13, weight: .semibold))

                HStack(spacing: 6) {
                    Text(provider.displayHost)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Text("·")
                        .foregroundStyle(.secondary.opacity(0.5))

                    Text("\(provider.keys.count) \(keysLabel(provider.keys.count))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Text("·")
                        .foregroundStyle(.secondary.opacity(0.5))

                    Text("\(provider.models.count) \(modelsLabel(provider.models.count))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Delete button — visible on hover
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Удалить провайдера")
            .opacity(isHovered ? 1 : 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.4))
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onTap() }
    }

    private func keysLabel(_ count: Int) -> String {
        switch count {
        case 1: return "ключ"
        case 2...4: return "ключа"
        default: return "ключей"
        }
    }

    private func modelsLabel(_ count: Int) -> String {
        switch count {
        case 1: return "модель"
        case 2...4: return "модели"
        default: return "моделей"
        }
    }
}

// MARK: - ProviderDetailView

struct ProviderDetailView: View {

    // MARK: - Input

    let provider: AIProvider
    var viewModel: ChappieViewModel
    let onBack: () -> Void

    // MARK: - State

    @State private var currentProvider: AIProvider
    @State private var showEditProvider: Bool = false
    @State private var showAddKey: Bool = false
    @State private var editingKey: APIKey? = nil
    @State private var deleteKeyId: UUID? = nil
    @State private var showAddModel: Bool = false
    @State private var deleteModelId: String? = nil
    @State private var errorMessage: String? = nil

    init(provider: AIProvider, viewModel: ChappieViewModel, onBack: @escaping () -> Void) {
        self.provider = provider
        self.viewModel = viewModel
        self.onBack = onBack
        self._currentProvider = State(initialValue: provider)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header with back button
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Провайдеры")
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    showEditProvider = true
                } label: {
                    Label("Редактировать", systemImage: "pencil")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            // Provider info card
            providerInfoCard
                .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    keysSection
                        .padding(.bottom, 8)

                    Divider()
                        .padding(.vertical, 8)

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
        // Edit mode uses AddProviderSheet directly (no catalog picker needed for editing)
        .sheet(isPresented: $showEditProvider) {
            AddProviderSheet(
                providerStore: viewModel.providerStore,
                editingProvider: currentProvider,
                onSaved: {
                    showEditProvider = false
                    viewModel.reloadProviders()
                    refreshCurrentProvider()
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
                    refreshCurrentProvider()
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
                    refreshCurrentProvider()
                },
                onCancel: { editingKey = nil }
            )
        }
        .sheet(isPresented: $showAddModel) {
            AddModelSheet(
                provider: currentProvider,
                existingModels: currentProvider.models,
                providerStore: viewModel.providerStore,
                onSaved: { newModels in
                    showAddModel = false
                    addModels(newModels)
                },
                onCancel: { showAddModel = false }
            )
        }
        .alert("Удалить ключ?", isPresented: Binding(
            get: { deleteKeyId != nil },
            set: { if !$0 { deleteKeyId = nil } }
        )) {
            Button("Удалить", role: .destructive) {
                if let id = deleteKeyId { deleteKey(id: id) }
                deleteKeyId = nil
            }
            Button("Отмена", role: .cancel) { deleteKeyId = nil }
        } message: {
            Text("Ключ будет удалён из Keychain. Треды, использующие этот ключ, покажут предупреждение.")
        }
        .alert("Удалить модель?", isPresented: Binding(
            get: { deleteModelId != nil },
            set: { if !$0 { deleteModelId = nil } }
        )) {
            Button("Удалить", role: .destructive) {
                if let id = deleteModelId { deleteModel(id) }
                deleteModelId = nil
            }
            Button("Отмена", role: .cancel) { deleteModelId = nil }
        } message: {
            Text("Треды, использующие эту модель, покажут предупреждение.")
        }
    }

    // MARK: - Provider Info Card

    private var providerInfoCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor.opacity(0.8))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(currentProvider.displayName)
                        .font(.system(size: 15, weight: .semibold))

                    // Catalog badge
                    if currentProvider.isFromCatalog {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor.opacity(0.7))
                            .help("Из каталога провайдеров")
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
                Text("Ключи")
                    .font(.headline)
                Text("(\(currentProvider.keys.count))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { showAddKey = true } label: {
                    Label("Добавить", systemImage: "plus")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }

            if currentProvider.keys.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Нет ключей — провайдер недоступен для использования в тредах.")
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
                Text("Модели")
                    .font(.headline)
                Text("(\(currentProvider.models.count))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { showAddModel = true } label: {
                    Label("Добавить", systemImage: "plus")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }

            if currentProvider.models.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary.opacity(0.4))
                    Text("Нет сохранённых моделей")
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
                refreshCurrentProvider()
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
                refreshCurrentProvider()
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
                refreshCurrentProvider()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshCurrentProvider() {
        if let updated = viewModel.providers.first(where: { $0.id == currentProvider.id }) {
            currentProvider = updated
        }
    }
}

// MARK: - KeyRow

private struct KeyRow: View {

    let key: APIKey
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor.opacity(0.7))

            Text(key.name)
                .font(.system(size: 13, weight: .medium))

            Text("••••••••")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.5))

            Spacer()

            HStack(spacing: 8) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Редактировать ключ")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Удалить ключ")
            }
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - ModelRow

private struct ModelRow: View {

    let model: AIModel
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cpu")
                .font(.system(size: 12))
                .foregroundStyle(.secondary.opacity(0.5))

            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.primary)

                if model.providerProtocol == .anthropic {
                    Text("anthropic")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                }
            }

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Удалить модель")
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
