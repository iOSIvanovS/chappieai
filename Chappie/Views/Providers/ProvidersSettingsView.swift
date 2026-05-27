// ProvidersSettingsView.swift
// Chappie
//
// Two-level settings for AI providers.
//
// LEVEL 1 — Provider list:
//   Shows all configured providers. Tap → drill into provider detail.
//   Add / delete providers freely (no "can't delete last" guard).
//
// LEVEL 2 — Provider detail (ProviderDetailView):
//   Shows provider info (name, endpoint, default badge).
//   Shows list of saved models — add new ones, delete existing ones.
//   Edit provider (name, endpoint, key) via AddProviderSheet.
//
// ORPHANED THREADS:
//   Deleting a provider or model is always allowed.
//   Affected threads show a warning banner in the chat view.

import SwiftUI
import ChappieCore

// MARK: - ProvidersSettingsView

struct ProvidersSettingsView: View {

    // MARK: - Dependencies

    var viewModel: ChappieViewModel

    // MARK: - State

    @State private var showAddProvider: Bool = false
    @State private var selectedProvider: AIProvider? = nil  // drill into detail
    @State private var deleteConfirmId: UUID? = nil
    @State private var errorMessage: String? = nil

    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        NavigationStack {
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
            .frame(width: 560, height: 440)
            .navigationDestination(item: $selectedProvider) { provider in
                ProviderDetailView(
                    provider: provider,
                    viewModel: viewModel,
                    onBack: { selectedProvider = nil }
                )
            }
        }
        .sheet(isPresented: $showAddProvider) {
            AddProviderSheet(
                providerStore: viewModel.providerStore,
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
            Text("Провайдер и его API-ключ будут удалены. Треды, использующие этого провайдера, покажут предупреждение.")
        }
    }

    // MARK: - Provider List

    private var providerList: some View {
        List {
            ForEach(viewModel.providers) { provider in
                ProviderListRow(
                    provider: provider,
                    isActive: viewModel.activeProvider?.id == provider.id,
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
    let isActive: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {

            // Active indicator
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.25))

            // Info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(provider.displayName)
                        .font(.system(size: 13, weight: .semibold))

                    if isActive {
                        Text("активный")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }

                HStack(spacing: 6) {
                    Text(provider.displayHost)
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

            // Delete
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Удалить провайдера")
            .opacity(isHovered ? 1 : 0)

            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.4))
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onTap() }
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
    @State private var showAddModel: Bool = false
    @State private var newModelName: String = ""
    @State private var deleteModelName: String? = nil
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

            // Header
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Назад")
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

            // Provider info card
            providerInfoCard

            Divider()
                .padding(.vertical, 12)

            // Models section header
            HStack {
                Text("Модели")
                    .font(.headline)

                Spacer()

                Button {
                    showAddModel = true
                } label: {
                    Label("Добавить", systemImage: "plus")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)

            if currentProvider.models.isEmpty {
                modelsEmptyState
            } else {
                modelsList
            }

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }

            Spacer(minLength: 0)
        }
        .frame(width: 560)
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
        .alert("Добавить модель", isPresented: $showAddModel) {
            TextField("Название модели", text: $newModelName)
            Button("Добавить") { addModel() }
            Button("Отмена", role: .cancel) { newModelName = "" }
        } message: {
            Text("Введите точное название модели, например: claude-sonnet-4-5")
        }
        .alert("Удалить модель?", isPresented: Binding(
            get: { deleteModelName != nil },
            set: { if !$0 { deleteModelName = nil } }
        )) {
            Button("Удалить", role: .destructive) {
                if let name = deleteModelName { deleteModel(name) }
                deleteModelName = nil
            }
            Button("Отмена", role: .cancel) { deleteModelName = nil }
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
                HStack(spacing: 8) {
                    Text(currentProvider.displayName)
                        .font(.system(size: 15, weight: .semibold))

                    if viewModel.activeProvider?.id == currentProvider.id {
                        Text("активный")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }

                Text(currentProvider.endpoint)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 24)
    }

    // MARK: - Models List

    private var modelsList: some View {
        List {
            ForEach(currentProvider.models, id: \.self) { model in
                ModelListRow(
                    model: model,
                    isActive: viewModel.activeProvider?.id == currentProvider.id
                                && viewModel.activeModelName == model,
                    onSelect: { selectModel(model) },
                    onDelete: { deleteModelName = model }
                )
            }
        }
        .listStyle(.inset)
        .frame(maxHeight: 240)
    }

    // MARK: - Models Empty State

    private var modelsEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 32))
                .foregroundStyle(.secondary.opacity(0.4))
            Text("Нет сохранённых моделей")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            Text("Нажмите «Добавить» чтобы добавить модель")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Actions

    private func selectModel(_ modelName: String) {
        viewModel.switchModel(to: modelName)
    }

    private func addModel() {
        let trimmed = newModelName.trimmingCharacters(in: .whitespaces)
        newModelName = ""
        guard !trimmed.isEmpty, let store = viewModel.providerStore else { return }

        Task {
            do {
                try await store.addModel(trimmed, toProviderId: currentProvider.id)
                viewModel.reloadProviders()
                refreshCurrentProvider()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteModel(_ modelName: String) {
        guard let store = viewModel.providerStore else { return }
        Task {
            do {
                try await store.deleteModel(modelName, fromProviderId: currentProvider.id)
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

// MARK: - ModelListRow

private struct ModelListRow: View {

    let model: String
    let isActive: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {

            // Active indicator / select button
            Button(action: onSelect) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.25))
            }
            .buttonStyle(.plain)
            .help(isActive ? "Активная модель" : "Использовать эту модель")

            Text(model)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.primary)

            if isActive {
                Text("активная")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }

            Spacer()

            // Delete
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Удалить модель")
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.vertical, 4)
        .onHover { isHovered = $0 }
    }
}
