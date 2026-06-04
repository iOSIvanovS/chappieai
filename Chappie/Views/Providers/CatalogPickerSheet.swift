// CatalogPickerSheet.swift
// Chappie
//
// First screen when adding a provider: choose from the remote catalog or enter manually.
//
// FLOW:
// 1. Sheet opens → catalog loads from ProvidersRemoteService (once per session).
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
                Text("Добавить провайдера")
                    .font(.title2.bold())
                Text("Выберите из каталога или настройте вручную")
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
            Text("Загружаем каталог…")
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
            Text("Не удалось загрузить каталог")
                .font(.subheadline.bold())
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Попробовать снова") { loadCatalog() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
    }

    private var catalogList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                // Catalog rows
                ForEach(catalog) { remote in
                    CatalogProviderRow(remote: remote) {
                        selectedRemote = remote
                    }
                }

                // Divider before custom option
                if !catalog.isEmpty {
                    Divider()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                }

                // Custom settings row — always last
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
            Button("Отмена") { onCancel() }
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
                let service = ProvidersRemoteService()
                let result = try await service.fetchCatalog()
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

// MARK: - CatalogProviderRow

private struct CatalogProviderRow: View {

    let remote: RemoteProvider
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                // Provider icon placeholder — letter avatar
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Text(String(remote.name.prefix(1)).uppercased())
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(remote.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    HStack(spacing: 6) {
                        Text(URL(string: remote.baseURL)?.host ?? remote.baseURL)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        Text("·")
                            .foregroundStyle(.secondary.opacity(0.4))

                        Text("\(remote.models.count) \(modelsLabel(remote.models.count))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(isHovered ? 0.6 : 0.3))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private func modelsLabel(_ count: Int) -> String {
        switch count % 10 {
        case 1 where count % 100 != 11: return "модель"
        case 2...4 where !(11...14).contains(count % 100): return "модели"
        default: return "моделей"
        }
    }
}

// MARK: - CustomProviderRow

private struct CustomProviderRow: View {

    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: 36, height: 36)
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Ручная настройка")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("Введите URL, ключ и модели самостоятельно")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(isHovered ? 0.6 : 0.3))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Preview

#Preview {
    CatalogPickerSheet(
        providerStore: nil,
        onSaved: {},
        onCancel: {}
    )
}
