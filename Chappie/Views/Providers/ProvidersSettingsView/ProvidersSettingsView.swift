// ProvidersSettingsView.swift
// Chappie
//
// Two-level directory view for AI providers.
// This is a READ/MANAGE view — no active provider selection happens here.
// Selection of provider+key+model happens at the thread level.
//
// LEVEL 1 — Provider list:
//   Shows all configured providers. Tap → drill into provider detail.
//   "Add Provider" → opens CatalogPickerSheet (catalog list + custom option).
//
// LEVEL 2 — ProviderDetailView (separate file).
//
// NAVIGATION:
//   Uses if/else state switch instead of NavigationStack — NavigationStack
//   inside a sheet on macOS does not behave as drill-down, it creates a full
//   navigation window which breaks the sheet layout.
//
// LIVE UPDATES:
//   Both ProvidersSettingsView and ProviderDetailView receive viewModel as a plain
//   var — @Observable tracks property access automatically, so viewModel.providers
//   changes propagate immediately without manual refresh.

import SwiftUI
import ChappieCore

// MARK: - ProvidersSettingsView

struct ProvidersSettingsView: View {

    // Plain var — @Observable on ChappieViewModel handles reactivity automatically.
    var viewModel: ChappieViewModel

    @State private var showAddProvider: Bool = false
    @State private var selectedProvider: AIProvider? = nil
    @State private var deleteConfirmId: UUID? = nil
    @State private var errorMessage: String? = nil

    @Environment(\.dismiss) private var dismiss

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
        .alert("providers.delete_title", isPresented: Binding(
            get: { deleteConfirmId != nil },
            set: { if !$0 { deleteConfirmId = nil } }
        )) {
            Button("providers.delete_confirm", role: .destructive) {
                if let id = deleteConfirmId { deleteProvider(id: id) }
                deleteConfirmId = nil
            }
            Button("providers.delete_cancel", role: .cancel) { deleteConfirmId = nil }
        } message: {
            Text("providers.delete_message")
        }
    }

    // MARK: - Provider List View

    private var providerListView: some View {
        VStack(alignment: .leading, spacing: 0) {

            HStack {
                Image(systemName: "cpu")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("providers.title")
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

            HStack {
                Button {
                    showAddProvider = true
                } label: {
                    Label("providers.add", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                if let err = errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }

                Button("providers.close") { dismiss() }
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
            Text("providers.empty_title")
                .font(.title3.bold())
                .foregroundStyle(.secondary)
            Text("providers.empty_hint")
                .font(.subheadline)
                .foregroundStyle(.secondary.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func deleteProvider(id: UUID) {
        guard let store = viewModel.providerStore else { return }
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

struct ProviderListRow: View {

    let provider: AIProvider
    let onTap: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {

            ProviderIconView(
                iconName: provider.iconName,
                iconColor: provider.resolvedIconColor,
                size: 32
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(provider.displayName)
                        .font(.system(size: 13, weight: .semibold))

                    // Custom badge — clearly marks manually added providers
                    if provider.origin == .custom {
                        Text("Custom")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }

                HStack(spacing: 6) {
                    Text(provider.displayHost)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    // Only show key count for providers that use keys
                    if provider.requiresApiKey {
                        Text("common.separator_dot")
                            .foregroundStyle(.secondary.opacity(0.5))
                        Text(verbatim: "\(provider.keys.count) \(keysLabel(provider.keys.count))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Text("common.separator_dot")
                        .foregroundStyle(.secondary.opacity(0.5))

                    Text(verbatim: "\(provider.models.count) \(modelsLabel(provider.models.count))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("providers.delete_help")
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
        String(localized: "format.key_count")
    }

    private func modelsLabel(_ count: Int) -> String {
        String(localized: "format.model_many")
    }
}
