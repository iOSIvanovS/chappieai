// CatalogPickerSheet.swift
// Chappie
//
// First screen when adding a provider: choose from the remote catalog or enter manually.
//
// FLOW:
// 1. Sheet opens → catalog loads via the shared ProvidersRemoteService (cached for the session).
// 2. User sees a list of known providers (OpenAI, Anthropic, Groq, …)
//    + a "Custom settings" row at the bottom.
// 3. Tapping a catalog row → opens AddProviderSheet pre-filled with
//    baseURL, catalogId, providerProtocol and all known models pre-selected.
// 4. Tapping "Custom settings" → opens AddProviderSheet with blank fields.
// 5. On save → calls onSaved() to reload the parent view.

import SwiftUI
import ChappieCore

// MARK: - CatalogPickerSheet

struct CatalogPickerSheet: View {

    // MARK: - Input

    let providerStore: AIProviderStore?
    /// Shared remote service — injected from ChappieViewModel to reuse the in-memory cache.
    let remoteService: ProvidersRemoteService
    var isOnboarding: Bool = false
    let onSaved: () -> Void
    let onCancel: () -> Void

    // MARK: - State

    @State private var catalog: [RemoteProvider] = []
    @State private var isLoading: Bool = false
    @State private var loadError: String? = nil
    @State private var selectedRemote: RemoteProvider? = nil  // catalog pick → AddProviderSheet
    @State private var showCustom: Bool = false               // custom pick → AddProviderSheet

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            content

            Divider()

            footer
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { loadCatalog() }
        // Catalog provider selected
        .sheet(item: $selectedRemote) { remote in
            AddProviderSheet(
                providerStore: providerStore,
                prefilledRemote: remote,
                isOnboarding: isOnboarding,
                onSaved: {
                    selectedRemote = nil
                    onSaved()
                },
                onCancel: { selectedRemote = nil }
            )
        }
        // Custom provider selected
        .sheet(isPresented: $showCustom) {
            AddProviderSheet(
                providerStore: providerStore,
                isOnboarding: isOnboarding,
                onSaved: {
                    showCustom = false
                    onSaved()
                },
                onCancel: { showCustom = false }
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "cpu.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("catalog.title")
                    .font(.title2.bold())
                Text("catalog.subtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { onCancel() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 20)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            loadingState
        } else if let err = loadError {
            errorState(err)
        } else {
            catalogList
        }
    }

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("catalog.loading")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("catalog.error_title")
                .font(.subheadline.bold())
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("catalog.retry") { loadCatalog() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
    }

    private var catalogList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(catalog) { remote in
                    CatalogProviderRow(remote: remote) {
                        selectedRemote = remote
                    }
                }

                if !catalog.isEmpty {
                    Divider()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                }

                CustomProviderRow {
                    showCustom = true
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(maxHeight: 360)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("catalog.cancel") { onCancel() }
                .keyboardShortcut(.escape)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Load Catalog

    private func loadCatalog() {
        isLoading = true
        loadError = nil

        Task {
            do {
                let result = try await remoteService.fetchCatalog()
                await MainActor.run {
                    catalog = result.providers
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    loadError = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}
