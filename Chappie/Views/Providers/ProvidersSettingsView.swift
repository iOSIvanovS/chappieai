// ProvidersSettingsView.swift
// Chappie
//
// IT-10: Settings sheet for managing AI providers.
// Replaces the old SettingsView (which only managed the AITunnel API key).

import SwiftUI
import ChappieCore

// MARK: - ProvidersSettingsView

struct ProvidersSettingsView: View {

    // MARK: - Dependencies

    // @Observable ViewModel — passed as plain parameter
    var viewModel: ChappieViewModel

    // MARK: - State

    @State private var showAddProvider: Bool = false
    @State private var editingProvider: AIProvider? = nil
    @State private var deleteConfirmId: UUID? = nil
    @State private var errorMessage: String? = nil

    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
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

                Button("Закрыть") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 560, height: 420)
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
        .sheet(item: $editingProvider) { provider in
            AddProviderSheet(
                providerStore: viewModel.providerStore,
                editingProvider: provider,
                onSaved: {
                    viewModel.reloadProviders()
                    editingProvider = nil
                },
                onCancel: { editingProvider = nil }
            )
        }
        .alert("Удалить провайдера?", isPresented: Binding(
            get: { deleteConfirmId != nil },
            set: { if !$0 { deleteConfirmId = nil } }
        )) {
            Button("Удалить", role: .destructive) {
                if let id = deleteConfirmId {
                    deleteProvider(id: id)
                }
                deleteConfirmId = nil
            }
            Button("Отмена", role: .cancel) { deleteConfirmId = nil }
        } message: {
            Text("Это действие нельзя отменить. API-ключ провайдера будет удалён из Keychain.")
        }
    }

    // MARK: - Provider List

    private var providerList: some View {
        List {
            ForEach(viewModel.providers) { provider in
                ProviderListRow(
                    provider: provider,
                    isActive: viewModel.activeProvider?.id == provider.id,
                    canDelete: viewModel.providers.count > 1,
                    onSelect: { viewModel.switchProvider(id: provider.id) },
                    onEdit: { editingProvider = provider },
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
                if viewModel.activeProvider?.id == id,
                   let first = viewModel.providers.first(where: { $0.id != id }),
                   let provStore = viewModel.providerStore {
                    await viewModel.switchProvider(first, from: provStore)
                }
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
    let canDelete: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.3))
            }
            .buttonStyle(.plain)
            .help(isActive ? "Активный провайдер" : "Выбрать этого провайдера")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(provider.modelName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    if isActive {
                        Text("активный")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }

                Text(provider.displayHost)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 4) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Редактировать")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(canDelete ? .red.opacity(0.7) : .secondary.opacity(0.3))
                }
                .buttonStyle(.plain)
                .disabled(!canDelete)
                .help(canDelete ? "Удалить" : "Нельзя удалить последнего провайдера")
            }
        }
        .padding(.vertical, 4)
    }
}
