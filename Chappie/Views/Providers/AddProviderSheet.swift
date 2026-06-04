// AddProviderSheet.swift
// Chappie
//
// Two-step sheet for adding or editing an AI provider.
//
// ENTRY POINTS:
// 1. From CatalogPickerSheet (catalog row) → prefilledRemote is set.
//    Step 1 is pre-filled: name, baseURL, catalogId, providerProtocol, models.
//    Models step shows catalog models pre-selected — user can deselect unwanted ones.
//    "Загрузить список" still works to discover additional live models.
//
// 2. From CatalogPickerSheet ("Ручная настройка") → prefilledRemote is nil.
//    Blank step 1. No catalog link. User enters everything manually.
//    Model step: no pre-selection, no catalog models — fetch or type manually.
//
// 3. Edit mode (editingProvider != nil) → opens on step 1 pre-filled with existing data.
//
// STEP 1 — Provider:
//   Enter base URL, API key (with user-defined name), optional provider name.
//   Validate provider (GET /v1/models — no model name needed).
//   On success → proceed to step 2.
//
//   ONBOARDING MODE (isOnboarding == true):
//     Shows a "+ Добавить ещё ключ" button to collect multiple keys before validation.
//     Each key has a name + value field. At least one key required.
//     Validation uses the first non-empty key.
//
//   DIRECTORY MODE (isOnboarding == false, default):
//     Single key field. On duplicate host → alert (do not add).
//     On duplicate key value → alert (do not add).
//
// STEP 2 — Models:
//   Catalog entry: models from catalog are shown pre-selected.
//   All entries: user can fetch live list, search, select/deselect, add manually.
//   Must add at least one model to proceed.
//
// SAVE BEHAVIOUR:
//   Onboarding → calls providerStore.mergeProvider (safe upsert, no alerts).
//   Directory  → calls providerStore.addProvider (strict add, shows alerts on duplicates).

import SwiftUI
import ChappieCore

// MARK: - PendingKey

private struct PendingKey: Identifiable {
    let id = UUID()
    var name: String = ""
    var value: String = ""
    var isVisible: Bool = false
}

// MARK: - AddProviderSheet

struct AddProviderSheet: View {

    // MARK: - Input

    let providerStore: AIProviderStore?
    /// Pre-filled from catalog picker. nil = custom / edit mode.
    var prefilledRemote: RemoteProvider? = nil
    var editingProvider: AIProvider? = nil
    var isOnboarding: Bool = false
    let onSaved: () -> Void
    let onCancel: () -> Void

    // MARK: - Step

    private enum Step { case provider, models }
    @State private var step: Step = .provider

    // MARK: - Step 1 State — shared

    @State private var providerName: String = ""
    @State private var baseURL: String = ""
    @State private var isValidating: Bool = false
    @State private var validationError: String? = nil
    @State private var validatedProvider: AIProvider? = nil

    // MARK: - Step 1 State — directory mode (single key)

    @State private var apiKeyValue: String = ""
    @State private var apiKeyName: String = ""
    @State private var isKeyVisible: Bool = false

    // MARK: - Step 1 State — onboarding mode (multi-key)

    @State private var pendingKeys: [PendingKey] = [PendingKey()]

    // MARK: - Step 2 State

    @State private var fetchedModels: [AIModel] = []
    @State private var selectedModelIds: Set<String> = []
    @State private var manualModelInput: String = ""
    @State private var isFetchingModels: Bool = false
    @State private var fetchError: String? = nil
    @State private var isSaving: Bool = false
    @State private var saveError: String? = nil
    @State private var modelSearchText: String = ""

    // MARK: - Duplicate Alerts

    @State private var duplicateHostAlert: Bool = false
    @State private var duplicateKeyValueAlert: Bool = false
    @State private var duplicateKeyNameAlert: Bool = false

    // MARK: - Computed

    private var isEditing: Bool { editingProvider != nil }
    private var isCatalog: Bool { prefilledRemote != nil }

    private var title: String { isEditing ? "Редактировать провайдера" : "Добавить провайдера" }

    private var canValidate: Bool {
        let urlOk = !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
        if isEditing { return urlOk }
        if isOnboarding {
            return urlOk && pendingKeys.contains(where: {
                !$0.value.trimmingCharacters(in: .whitespaces).isEmpty
            })
        } else {
            return urlOk && !apiKeyValue.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    // All models: fetched + catalog (for catalog mode) + existing (for edit mode)
    private var allModels: [AIModel] {
        var combined = fetchedModels
        if let existing = editingProvider {
            for m in existing.models where !combined.contains(where: { $0.id == m.id }) {
                combined.insert(m, at: 0)
            }
        }
        return combined
    }

    private var filteredModels: [AIModel] {
        let q = modelSearchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allModels }
        return allModels.filter {
            $0.id.lowercased().contains(q) || $0.name.lowercased().contains(q)
        }
    }

    private var canSave: Bool { !selectedModelIds.isEmpty }

    private var allFilteredSelected: Bool {
        !filteredModels.isEmpty && filteredModels.allSatisfy { selectedModelIds.contains($0.id) }
    }

    private var firstValidKeyValue: String {
        if isOnboarding {
            return pendingKeys.first(where: { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty })?.value ?? ""
        } else {
            return apiKeyValue
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {
                Image(systemName: isEditing ? "pencil.circle" : "plus.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title2.bold())
                    Text(step == .provider ? "Шаг 1 из 2 — Провайдер" : "Шаг 2 из 2 — Модели")
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

            switch step {
            case .provider: providerStep
            case .models:   modelsStep
            }

            Divider()

            footerButtons
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { prefill() }
        .alert("Провайдер уже существует", isPresented: $duplicateHostAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Провайдер с таким адресом уже добавлен в справочник.")
        }
        .alert("Ключ уже существует", isPresented: $duplicateKeyValueAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Ключ с таким значением уже добавлен у этого провайдера.")
        }
        .alert("Название занято", isPresented: $duplicateKeyNameAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Ключ с таким названием уже существует у этого провайдера. Выберите другое имя.")
        }
    }

    // MARK: - Step 1: Provider

    private var providerStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Catalog badge — shows which provider was picked
                if let remote = prefilledRemote {
                    catalogBadge(remote)
                }

                fieldSection(label: "Название провайдера", icon: "tag", hint: "Необязательно. Например: «Work OpenAI» или «Personal Groq»") {
                    TextField("Мой провайдер", text: $providerName)
                        .textFieldStyle(.roundedBorder)
                }

                fieldSection(label: "Базовый URL", icon: "link", hint: "Без пути, например: https://api.openai.com") {
                    TextField("https://...", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        // Lock URL for catalog providers — it's authoritative
                        .disabled(isCatalog && !isEditing)
                        .foregroundStyle(isCatalog && !isEditing ? .secondary : .primary)
                }

                if isOnboarding {
                    multiKeySection
                } else {
                    singleKeySection
                }

                if let err = validationError {
                    errorBanner(err)
                }
            }
            .padding(24)
        }
    }

    // MARK: - Catalog Badge

    @ViewBuilder
    private func catalogBadge(_ remote: RemoteProvider) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Из каталога: \(remote.name)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("\(remote.models.count) моделей в каталоге")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Single Key (Directory Mode)

    private var singleKeySection: some View {
        Group {
            fieldSection(
                label: "Название ключа",
                icon: "tag.fill",
                hint: "Понятное имя для этого ключа. Например: «Рабочий», «Личный», «Клиент X»"
            ) {
                TextField(isEditing ? "Новое название ключа" : "Рабочий ключ", text: $apiKeyName)
                    .textFieldStyle(.roundedBorder)
            }

            fieldSection(
                label: "API-ключ",
                icon: "key.fill",
                hint: isEditing ? "Оставьте пустым чтобы сохранить текущий ключ" : "Ключ будет сохранён в системном Keychain"
            ) {
                HStack(spacing: 8) {
                    Group {
                        if isKeyVisible {
                            TextField(isEditing ? "Новый ключ (необязательно)" : "sk-...", text: $apiKeyValue)
                        } else {
                            SecureField(isEditing ? "Новый ключ (необязательно)" : "sk-...", text: $apiKeyValue)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                    Button { isKeyVisible.toggle() } label: {
                        Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Multi-Key (Onboarding Mode)

    private var multiKeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("API-ключи", systemImage: "key.fill")
                .font(.headline)

            Text("Добавьте один или несколько ключей для этого провайдера. Все они будут доступны при выборе провайдера в треде.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach($pendingKeys) { $key in
                PendingKeyRow(key: $key, canDelete: pendingKeys.count > 1) {
                    pendingKeys.removeAll { $0.id == key.id }
                }
            }

            Button {
                pendingKeys.append(PendingKey())
            } label: {
                Label("Добавить ещё ключ", systemImage: "plus.circle")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }

    // MARK: - Step 2: Models

    private var modelsStep: some View {
        VStack(alignment: .leading, spacing: 0) {

            HStack(spacing: 12) {
                Button {
                    fetchModels()
                } label: {
                    HStack(spacing: 6) {
                        if isFetchingModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(isFetchingModels ? "Загружаем..." : "Загрузить список")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isFetchingModels)

                if !fetchedModels.isEmpty {
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

            if let fetchErr = fetchError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(fetchErr).font(.caption).foregroundStyle(.orange)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }

            Divider()

            if !allModels.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                    TextField("Поиск по названию…", text: $modelSearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                    if !modelSearchText.isEmpty {
                        Button {
                            modelSearchText = ""
                        } label: {
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

                Button {
                    toggleSelectAll()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: allFilteredSelected ? "checkmark.square.fill" : "square")
                            .font(.system(size: 14))
                            .foregroundStyle(allFilteredSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                        Text(allFilteredSelected ? "Снять выделение" : "Выбрать все")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        if !modelSearchText.isEmpty {
                            Text("(\(filteredModels.count) из \(allModels.count))")
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

            if allModels.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "cpu")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary.opacity(0.4))
                    Text("Нет загруженных моделей")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Загрузите список выше или добавьте модель вручную")
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else if filteredModels.isEmpty {
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
                            ModelCheckRow(
                                model: model,
                                isSelected: selectedModelIds.contains(model.id),
                                onToggle: {
                                    if selectedModelIds.contains(model.id) {
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

            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .foregroundStyle(.secondary)
                TextField("Добавить модель вручную…", text: $manualModelInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { addManualModel() }

                Button("Добавить") { addManualModel() }
                    .buttonStyle(.bordered)
                    .disabled(manualModelInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            if let err = saveError {
                errorBanner(err)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Footer Buttons

    private var footerButtons: some View {
        HStack {
            Button(step == .provider ? "Отмена" : "Назад") {
                if step == .provider {
                    onCancel()
                } else {
                    withAnimation { step = .provider }
                }
            }
            .keyboardShortcut(.escape)

            Spacer()

            if step == .provider {
                Button {
                    validateAndProceed()
                } label: {
                    HStack(spacing: 6) {
                        if isValidating {
                            ProgressView().controlSize(.small)
                            Text("Проверяем...")
                        } else {
                            Text("Далее")
                            Image(systemName: "arrow.right")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canValidate || isValidating)
                .keyboardShortcut(.return)
            } else {
                Button {
                    saveProvider()
                } label: {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView().controlSize(.small)
                            Text("Сохраняем...")
                        } else {
                            Text(isEditing ? "Сохранить" : "Добавить провайдера")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave || isSaving)
                .keyboardShortcut(.return)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Field Section Builder

    @ViewBuilder
    private func fieldSection<Content: View>(
        label: String,
        icon: String,
        hint: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: icon).font(.headline)
            content()
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            Text(message).font(.subheadline).foregroundStyle(.red)
        }
        .padding(12)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Pre-fill

    private func prefill() {
        if let provider = editingProvider {
            // Edit mode: fill from existing provider
            providerName = provider.name
            baseURL = provider.baseURL
            selectedModelIds = Set(provider.models.map { $0.id })
            apiKeyName = provider.keys.first?.name ?? ""
        } else if let remote = prefilledRemote {
            // Catalog mode: fill from RemoteProvider
            providerName = remote.name
            baseURL = remote.baseURL
            // Pre-populate catalog models and select all
            let catalogModels = remote.models.map { rm in
                AIModel(
                    id: rm.id,
                    name: rm.name,
                    endpoint: rm.endpoint,
                    providerProtocol: rm.protocol == "anthropic" ? .anthropic : .openai
                )
            }
            fetchedModels = catalogModels
            selectedModelIds = Set(catalogModels.map { $0.id })
        }
    }

    // MARK: - Select All Toggle

    private func toggleSelectAll() {
        if allFilteredSelected {
            for m in filteredModels { selectedModelIds.remove(m.id) }
        } else {
            for m in filteredModels { selectedModelIds.insert(m.id) }
        }
    }

    // MARK: - Step 1: Validate Provider

    private func validateAndProceed() {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespaces)

        guard !trimmedURL.isEmpty else {
            validationError = "Введите базовый URL."
            return
        }

        isValidating = true
        validationError = nil

        Task {
            // Directory mode: check for duplicate host before validating
            if !isOnboarding && !isEditing, let store = providerStore {
                let hostExists = await store.providerHostExists(trimmedURL)
                if hostExists {
                    await MainActor.run {
                        isValidating = false
                        duplicateHostAlert = true
                    }
                    return
                }
            }

            let keyToUse: String
            if isEditing && firstValidKeyValue.isEmpty, let existing = editingProvider,
               let store = providerStore,
               let firstKeyId = existing.keys.first?.id {
                keyToUse = await store.loadApiKey(for: firstKeyId) ?? ""
            } else {
                keyToUse = firstValidKeyValue
            }

            guard !keyToUse.isEmpty else {
                await MainActor.run {
                    isValidating = false
                    validationError = "Введите API-ключ."
                }
                return
            }

            let validationEndpoint = trimmedURL + "/v1/models"
            let client = AIClient(endpoint: validationEndpoint, apiKey: keyToUse, modelName: "")
            do {
                try await client.validateProvider()

                // Build provisional provider, preserving catalog metadata if present
                let provisional = AIProvider(
                    id: editingProvider?.id ?? UUID(),
                    name: providerName.trimmingCharacters(in: .whitespaces),
                    baseURL: trimmedURL,
                    catalogId: editingProvider?.catalogId ?? prefilledRemote?.id,
                    providerProtocol: editingProvider?.providerProtocol
                        ?? (prefilledRemote?.models.first?.protocol == "anthropic" ? .anthropic : .openai),
                    keys: editingProvider?.keys ?? [],
                    models: editingProvider?.models ?? []
                )

                await MainActor.run {
                    isValidating = false
                    validatedProvider = provisional
                    withAnimation { step = .models }
                    // Only auto-fetch if no catalog models are pre-loaded
                    if fetchedModels.isEmpty {
                        fetchModels()
                    }
                }

            } catch {
                await MainActor.run {
                    isValidating = false
                    validationError = "Ошибка подключения: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Step 2: Fetch Models

    private func fetchModels() {
        guard let provider = validatedProvider ?? editingProvider.map({
            AIProvider(
                id: $0.id, name: $0.name,
                baseURL: baseURL.trimmingCharacters(in: .whitespaces),
                catalogId: $0.catalogId,
                providerProtocol: $0.providerProtocol,
                keys: $0.keys, models: $0.models
            )
        }) else { return }

        isFetchingModels = true
        fetchError = nil

        Task {
            let keyToUse: String
            if isEditing && firstValidKeyValue.isEmpty, let existing = editingProvider,
               let store = providerStore,
               let firstKeyId = existing.keys.first?.id {
                keyToUse = await store.loadApiKey(for: firstKeyId) ?? ""
            } else {
                keyToUse = firstValidKeyValue
            }

            let discoveryEndpoint = provider.baseURL + "/v1/models"
            let client = AIClient(endpoint: discoveryEndpoint, apiKey: keyToUse, modelName: "")
            let modelIds = await client.fetchAvailableModels()

            await MainActor.run {
                isFetchingModels = false
                if modelIds.isEmpty {
                    fetchError = "Не удалось загрузить список моделей. Добавьте модели вручную."
                } else {
                    // Merge live models with existing catalog/edit models — preserve metadata
                    let existingModels = fetchedModels
                    fetchedModels = modelIds.map { modelId in
                        if let existing = existingModels.first(where: { $0.id == modelId }) {
                            return existing
                        }
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
                    fetchError = nil
                    // Auto-select newly fetched models only if nothing was selected yet
                    if selectedModelIds.isEmpty {
                        selectedModelIds = Set(modelIds)
                    }
                }
            }
        }
    }

    // MARK: - Step 2: Manual Model

    private func addManualModel() {
        let trimmed = manualModelInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !fetchedModels.contains(where: { $0.id == trimmed }) {
            let model = AIModel(
                id: trimmed,
                name: trimmed,
                endpoint: "/v1/chat/completions",
                providerProtocol: validatedProvider?.providerProtocol ?? .openai
            )
            fetchedModels.insert(model, at: 0)
        }
        selectedModelIds.insert(trimmed)
        manualModelInput = ""
    }

    // MARK: - Step 2: Save Provider

    private func saveProvider() {
        guard let store = providerStore,
              let provisional = validatedProvider ?? editingProvider else { return }

        isSaving = true
        saveError = nil

        let modelsToSave = allModels.filter { selectedModelIds.contains($0.id) }

        Task {
            do {
                var finalProvider = provisional
                finalProvider.models = modelsToSave

                if isEditing {
                    try await store.updateProvider(finalProvider)

                    let trimmedKeyValue = apiKeyValue.trimmingCharacters(in: .whitespaces)
                    let resolvedKeyName = apiKeyName.trimmingCharacters(in: .whitespaces)

                    if let firstKey = finalProvider.keys.first {
                        if !resolvedKeyName.isEmpty {
                            let otherKeys = finalProvider.keys.filter { $0.id != firstKey.id }
                            let nameCollision = otherKeys.contains(where: {
                                $0.name.lowercased() == resolvedKeyName.lowercased()
                            })
                            if nameCollision {
                                await MainActor.run {
                                    isSaving = false
                                    duplicateKeyNameAlert = true
                                }
                                return
                            }
                        }

                        if !trimmedKeyValue.isEmpty {
                            let otherKeys = finalProvider.keys.filter { $0.id != firstKey.id }
                            var valueCollision = false
                            for other in otherKeys {
                                if let stored = await store.loadApiKey(for: other.id), stored == trimmedKeyValue {
                                    valueCollision = true
                                    break
                                }
                            }
                            if valueCollision {
                                await MainActor.run {
                                    isSaving = false
                                    duplicateKeyValueAlert = true
                                }
                                return
                            }
                        }

                        var updatedKey = firstKey
                        if !resolvedKeyName.isEmpty { updatedKey.name = resolvedKeyName }
                        try await store.updateKey(
                            updatedKey,
                            newValue: trimmedKeyValue.isEmpty ? nil : trimmedKeyValue,
                            forProviderId: finalProvider.id
                        )
                    }

                } else if isOnboarding {
                    let validKeys = pendingKeys.filter {
                        !$0.value.trimmingCharacters(in: .whitespaces).isEmpty
                    }
                    guard let firstKey = validKeys.first else {
                        await MainActor.run {
                            isSaving = false
                            saveError = "Нужен хотя бы один ключ."
                        }
                        return
                    }

                    let providerId = try await store.mergeProvider(
                        finalProvider,
                        keyName: firstKey.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Default" : firstKey.name,
                        keyValue: firstKey.value.trimmingCharacters(in: .whitespaces),
                        models: modelsToSave
                    )

                    for key in validKeys.dropFirst() {
                        let name = key.name.trimmingCharacters(in: .whitespaces)
                        let value = key.value.trimmingCharacters(in: .whitespaces)
                        _ = try await store.mergeProvider(
                            AIProvider(id: providerId, name: finalProvider.name, baseURL: finalProvider.baseURL),
                            keyName: name.isEmpty ? "Key" : name,
                            keyValue: value,
                            models: []
                        )
                    }

                } else {
                    let trimmedKeyValue = apiKeyValue.trimmingCharacters(in: .whitespaces)
                    let resolvedKeyName = apiKeyName.trimmingCharacters(in: .whitespaces)
                    let keyName = resolvedKeyName.isEmpty ? "Default" : resolvedKeyName
                    try await store.addProvider(finalProvider, firstKeyName: keyName, firstKeyValue: trimmedKeyValue)
                }

                await MainActor.run {
                    isSaving = false
                    onSaved()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = "Ошибка сохранения: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - PendingKeyRow

private struct PendingKeyRow: View {

    @Binding var key: PendingKey
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Название ключа (напр. «Рабочий»)", text: $key.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)

                Group {
                    if key.isVisible {
                        TextField("sk-...", text: $key.value)
                    } else {
                        SecureField("sk-...", text: $key.value)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

                Button { key.isVisible.toggle() } label: {
                    Image(systemName: key.isVisible ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                if canDelete {
                    Button(action: onDelete) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - ModelCheckRow

private struct ModelCheckRow: View {

    let model: AIModel
    let isSelected: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))

                Text(model.displayName)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.07)
                          : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Preview

#Preview {
    AddProviderSheet(
        providerStore: nil,
        onSaved: {},
        onCancel: {}
    )
}
