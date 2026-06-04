// AddModelSheet.swift
// Chappie
//
// Reusable sheet for adding models to a provider.
// Used in: ProviderDetailView (settings), AddProviderSheet step 2.
//
// FLOW (catalog provider):
//   1. Sheet opens — loads models from remote catalog via ProvidersRemoteService (no network to provider).
//   2. User selects which catalog models to add.
//   3. Manual input still available for models not in catalog.
//
// FLOW (custom provider):
//   1. Sheet opens — shows empty list.
//   2. User taps "Загрузить список" to fetch from provider endpoint, or adds manually.
//
// DEDUPLICATION:
//   existingModels are shown as already-added (greyed out, not selectable).
//   Only new models can be selected and returned.

import SwiftUI
import ChappieCore

// MARK: - AddModelSheet

struct AddModelSheet: View {

    // MARK: - Input

    let provider: AIProvider
    let existingModels: [AIModel]
    let providerStore: AIProviderStore?
    let remoteService: ProvidersRemoteService?
    let onSaved: ([AIModel]) -> Void
    let onCancel: () -> Void

    // MARK: - State

    @State private var catalogModels: [AIModel] = []
    @State private var fetchedModels: [AIModel] = []
    @State private var manualModels: [AIModel] = []
    @State private var selectedModelIds: Set<String> = []
    @State private var manualInput: String = ""
    @State private var searchText: String = ""
    @State private var isLoading: Bool = false
    @State private var loadError: String? = nil
    @State private var isSaving: Bool = false
    @State private var saveError: String? = nil

    // MARK: - Computed

    /// True if provider comes from catalog — use catalog as model source.
    private var isCatalog: Bool { provider.catalogId != nil }

    private var existingIds: Set<String> { Set(existingModels.map { $0.id }) }

    private var allModels: [AIModel] {
        var result = manualModels
        let source = isCatalog ? catalogModels : fetchedModels
        for m in source where !result.contains(where: { $0.id == m.id }) {
            result.append(m)
        }
        return result
    }

    private var filteredModels: [AIModel] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allModels }
        return allModels.filter {
            $0.id.lowercased().contains(q) || $0.name.lowercased().contains(q)
        }
    }

    private var canSave: Bool { !selectedModelIds.isEmpty }

    private var allFilteredSelected: Bool {
        let selectable = filteredModels.filter { !existingIds.contains($0.id) }
        return !selectable.isEmpty && selectable.allSatisfy { selectedModelIds.contains($0.id) }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {
                Image(systemName: "plus.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Добавить модели")
                        .font(.title2.bold())
                    Text(provider.displayName)
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

            Divider()

            // Load controls — only for custom providers
            if !isCatalog {
                HStack(spacing: 12) {
                    Button { fetchFromProvider() } label: {
                        HStack(spacing: 6) {
                            if isLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(isLoading ? "Загружаем..." : "Загрузить список")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoading)

                    if !allModels.isEmpty {
                        Text("\(allModels.count) моделей")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text("Выбрано: \(selectedModelIds.count)")
                        .font(.caption)
                        .foregroundStyle(selectedModelIds.isEmpty ? .orange : .secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 8)
            } else {
                HStack {
                    if isLoading {
                        ProgressView().controlSize(.small)
                        Text("Загружаем из каталога...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(allModels.count) моделей в каталоге")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Выбрано: \(selectedModelIds.count)")
                        .font(.caption)
                        .foregroundStyle(selectedModelIds.isEmpty ? .orange : .secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 8)
            }

            if let err = loadError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }

            Divider()

            // Search bar
            if !allModels.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                    TextField("Поиск по названию…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.04))

                Button { toggleSelectAll() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: allFilteredSelected ? "checkmark.square.fill" : "square")
                            .font(.system(size: 14))
                            .foregroundStyle(allFilteredSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                        Text(allFilteredSelected ? "Снять выделение" : "Выбрать все")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        if !searchText.isEmpty {
                            Text("(\(filteredModels.filter { !existingIds.contains($0.id) }.count) доступных)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary.opacity(0.7))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .background(Color.primary.opacity(0.02))

                Divider()
            }

            // Model list
            if allModels.isEmpty && !isLoading {
                VStack(spacing: 8) {
                    Image(systemName: "cpu")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary.opacity(0.4))
                    Text("Нет моделей")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(isCatalog
                         ? "Модели не найдены в каталоге. Добавьте вручную."
                         : "Загрузите список выше или добавьте модель вручную")
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else if filteredModels.isEmpty && !isLoading {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary.opacity(0.4))
                    Text("Ничего не найдено")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredModels) { model in
                            let isExisting = existingIds.contains(model.id)
                            let isSelected = selectedModelIds.contains(model.id)

                            ModelSelectRow(
                                model: model,
                                isSelected: isSelected,
                                isExisting: isExisting,
                                onToggle: {
                                    guard !isExisting else { return }
                                    if isSelected {
                                        selectedModelIds.remove(model.id)
                                    } else {
                                        selectedModelIds.insert(model.id)
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 240)
            }

            Divider()

            // Manual input
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .foregroundStyle(.secondary)
                TextField("Добавить модель вручную…", text: $manualInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { addManual() }
                Button("Добавить") { addManual() }
                    .buttonStyle(.bordered)
                    .disabled(manualInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            if let err = saveError {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(err).font(.subheadline).foregroundStyle(.red)
                }
                .padding(.horizontal, 24)
                .padding(12)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 24)
            }

            Divider()

            // Footer
            HStack {
                Button("Отмена") { onCancel() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button {
                    confirmSave()
                } label: {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView().controlSize(.small)
                            Text("Добавляем...")
                        } else {
                            Text("Добавить (\(selectedModelIds.count))")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave || isSaving)
                .keyboardShortcut(.return)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { loadModels() }
    }

    // MARK: - Load Models

    private func loadModels() {
        if isCatalog {
            loadFromCatalog()
        }
        // Custom providers: don't auto-fetch — user taps button explicitly
    }

    /// Load models from remote catalog for catalog-linked providers.
    private func loadFromCatalog() {
        guard let catalogId = provider.catalogId,
              let service = remoteService else { return }

        isLoading = true
        loadError = nil

        Task {
            // Catalog should already be cached from app launch fetch
            if let remote = await service.findProvider(byCatalogId: catalogId) {
                let models = remote.models.map { rm in
                    AIModel(
                        id: rm.id,
                        name: rm.name,
                        endpoint: rm.endpoint,
                        providerProtocol: rm.protocol == "anthropic" ? .anthropic : .openai
                    )
                }
                await MainActor.run {
                    catalogModels = models
                    isLoading = false
                    // Auto-select all non-existing models
                    for m in models where !existingIds.contains(m.id) {
                        selectedModelIds.insert(m.id)
                    }
                }
            } else {
                // Catalog not cached yet — fetch it
                do {
                    let catalog = try await service.fetchCatalog()
                    if let remote = catalog.providers.first(where: { $0.id == catalogId }) {
                        let models = remote.models.map { rm in
                            AIModel(
                                id: rm.id,
                                name: rm.name,
                                endpoint: rm.endpoint,
                                providerProtocol: rm.protocol == "anthropic" ? .anthropic : .openai
                            )
                        }
                        await MainActor.run {
                            catalogModels = models
                            isLoading = false
                            for m in models where !existingIds.contains(m.id) {
                                selectedModelIds.insert(m.id)
                            }
                        }
                    } else {
                        await MainActor.run {
                            isLoading = false
                            loadError = "Провайдер не найден в каталоге. Добавьте модели вручную."
                        }
                    }
                } catch {
                    await MainActor.run {
                        isLoading = false
                        loadError = "Не удалось загрузить каталог: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    /// Fetch models from provider endpoint — only for custom providers.
    private func fetchFromProvider() {
        guard let store = providerStore else { return }
        isLoading = true
        loadError = nil

        Task {
            let keySecret: String
            if let firstKey = provider.keys.first {
                keySecret = await store.loadApiKey(for: firstKey.id) ?? ""
            } else {
                keySecret = ""
            }

            guard !keySecret.isEmpty else {
                await MainActor.run {
                    isLoading = false
                    loadError = "Нет ключей для этого провайдера."
                }
                return
            }

            let client = AIClientFactory.makeForValidation(
                baseURL: provider.baseURL,
                apiKey: keySecret,
                providerProtocol: provider.providerProtocol,
                authScheme: provider.authScheme
            )
            let modelIds = await client.fetchAvailableModels()

            await MainActor.run {
                isLoading = false
                if modelIds.isEmpty {
                    loadError = "Не удалось загрузить список. Добавьте модели вручную."
                } else {
                    fetchedModels = modelIds.map { modelId in
                        if let existing = provider.models.first(where: { $0.id == modelId }) {
                            return existing
                        }
                        return AIModel(
                            id: modelId,
                            name: modelId,
                            endpoint: "/v1/chat/completions",
                            providerProtocol: provider.providerProtocol
                        )
                    }
                    for m in fetchedModels where !existingIds.contains(m.id) {
                        selectedModelIds.insert(m.id)
                    }
                }
            }
        }
    }

    // MARK: - Manual Add

    private func addManual() {
        let trimmed = manualInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let allExisting = catalogModels + fetchedModels + manualModels
        if !allExisting.contains(where: { $0.id == trimmed }) {
            let model = AIModel(
                id: trimmed,
                name: trimmed,
                endpoint: provider.providerProtocol == .anthropic ? "/v1/messages" : "/v1/chat/completions",
                providerProtocol: provider.providerProtocol
            )
            manualModels.insert(model, at: 0)
        }
        if !existingIds.contains(trimmed) {
            selectedModelIds.insert(trimmed)
        }
        manualInput = ""
    }

    // MARK: - Select All Toggle

    private func toggleSelectAll() {
        let selectable = filteredModels.filter { !existingIds.contains($0.id) }
        if allFilteredSelected {
            for m in selectable { selectedModelIds.remove(m.id) }
        } else {
            for m in selectable { selectedModelIds.insert(m.id) }
        }
    }

    // MARK: - Confirm

    private func confirmSave() {
        let newModels = allModels
            .filter { selectedModelIds.contains($0.id) && !existingIds.contains($0.id) }
            .sorted { $0.id < $1.id }
        guard !newModels.isEmpty else { return }
        onSaved(newModels)
    }
}

// MARK: - ModelSelectRow

private struct ModelSelectRow: View {

    let model: AIModel
    let isSelected: Bool
    let isExisting: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                if isExisting {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.secondary.opacity(0.35))
                } else {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 16))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
                }

                Text(model.displayName)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(isExisting ? .secondary : .primary)
                    .lineLimit(1)

                if isExisting {
                    Text("добавлена")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isExisting
                          ? Color.clear
                          : (isSelected
                             ? Color.accentColor.opacity(0.07)
                             : (isHovered ? Color.primary.opacity(0.04) : Color.clear)))
            )
        }
        .buttonStyle(.plain)
        .disabled(isExisting)
        .onHover { isHovered = $0 }
    }
}
