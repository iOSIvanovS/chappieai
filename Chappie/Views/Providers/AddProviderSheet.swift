// AddProviderSheet.swift
// Chappie
//
// Two-step sheet for adding a new AI provider.
//
// STEP 1 — Provider:
//   Enter endpoint URL, API key (with user-defined name), optional provider name.
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
//   Fetch available models from the provider (auto-populated if /models works).
//   User can select from the list OR type model names manually.
//   Search bar filters the visible list in real time.
//   "Select all / deselect all" toggle at the top.
//   Must add at least one model to proceed.
//
// EDIT MODE:
//   Opens directly on step 1 pre-filled with existing data.
//   API key field shows placeholder (existing key preserved if left empty).
//   Key name field editable — rename the key without changing the secret.
//   Models list is editable — add/remove individual models.
//
// SAVE BEHAVIOUR:
//   Onboarding → calls providerStore.mergeProvider (safe upsert, no alerts).
//   Directory  → calls providerStore.addProvider (strict add, shows alerts on duplicates).

import SwiftUI
import ChappieCore

// MARK: - PendingKey

/// A key being composed in the onboarding multi-key UI (before saving).
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
    var editingProvider: AIProvider? = nil
    /// When true: multi-key input, merge-save (onboarding). When false: single-key, strict-save (directory).
    var isOnboarding: Bool = false
    let onSaved: () -> Void
    let onCancel: () -> Void

    // MARK: - Step

    private enum Step { case provider, models }
    @State private var step: Step = .provider

    // MARK: - Step 1 State — shared

    @State private var providerName: String = ""
    @State private var endpoint: String = ""
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

    @State private var fetchedModels: [String] = []
    @State private var selectedModels: Set<String> = []
    @State private var manualModelInput: String = ""
    @State private var isFetchingModels: Bool = false
    @State private var fetchError: String? = nil
    @State private var isSaving: Bool = false
    @State private var saveError: String? = nil
    @State private var modelSearchText: String = ""

    // MARK: - Duplicate Alerts (directory mode)

    @State private var duplicateHostAlert: Bool = false
    @State private var duplicateKeyAlert: Bool = false

    // MARK: - Computed

    private var isEditing: Bool { editingProvider != nil }
    private var title: String { isEditing ? "Редактировать провайдера" : "Добавить провайдера" }

    private var canValidate: Bool {
        let endpointOk = !endpoint.trimmingCharacters(in: .whitespaces).isEmpty
        if isEditing { return endpointOk }
        if isOnboarding {
            // At least one key with a non-empty value
            return endpointOk && pendingKeys.contains(where: {
                !$0.value.trimmingCharacters(in: .whitespaces).isEmpty
            })
        } else {
            return endpointOk && !apiKeyValue.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    // All models: fetched + manually added + existing (for edit mode)
    private var allModels: [String] {
        var combined = fetchedModels
        if let existing = editingProvider {
            for m in existing.models where !combined.contains(m) {
                combined.insert(m, at: 0)
            }
        }
        return combined
    }

    // Filtered by search text
    private var filteredModels: [String] {
        let q = modelSearchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allModels }
        return allModels.filter { $0.lowercased().contains(q) }
    }

    private var canSave: Bool { !selectedModels.isEmpty }

    private var allFilteredSelected: Bool {
        !filteredModels.isEmpty && filteredModels.allSatisfy { selectedModels.contains($0) }
    }

    // First non-empty key value for validation
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
        .onAppear { prefillIfEditing() }
        .alert("Провайдер уже существует", isPresented: $duplicateHostAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Провайдер с таким адресом уже добавлен в справочник.")
        }
        .alert("Ключ уже существует", isPresented: $duplicateKeyAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Ключ с таким значением уже добавлен у этого провайдера.")
        }
    }

    // MARK: - Step 1: Provider

    private var providerStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                fieldSection(label: "Название провайдера", icon: "tag", hint: "Необязательно. Например: «Work OpenAI» или «Personal Groq»") {
                    TextField("Мой провайдер", text: $providerName)
                        .textFieldStyle(.roundedBorder)
                }

                fieldSection(label: "Эндпойнт", icon: "link", hint: "Полный URL, например: https://api.aitunnel.ru/v1/chat/completions") {
                    TextField("https://...", text: $endpoint)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                // Keys section — single in directory mode, multi in onboarding
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

                Text("Выбрано: \(selectedModels.count)")
                    .font(.caption)
                    .foregroundStyle(selectedModels.isEmpty ? .orange : .secondary)
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
                        ForEach(filteredModels, id: \.self) { model in
                            ModelCheckRow(
                                model: model,
                                isSelected: selectedModels.contains(model),
                                onToggle: {
                                    if selectedModels.contains(model) {
                                        selectedModels.remove(model)
                                    } else {
                                        selectedModels.insert(model)
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

    private func prefillIfEditing() {
        guard let provider = editingProvider else { return }
        providerName = provider.name
        endpoint = provider.endpoint
        selectedModels = Set(provider.models)
        apiKeyName = provider.keys.first?.name ?? ""
    }

    // MARK: - Select All Toggle

    private func toggleSelectAll() {
        if allFilteredSelected {
            for m in filteredModels { selectedModels.remove(m) }
        } else {
            for m in filteredModels { selectedModels.insert(m) }
        }
    }

    // MARK: - Step 1: Validate Provider

    private func validateAndProceed() {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespaces)

        guard !trimmedEndpoint.isEmpty else {
            validationError = "Введите URL эндпойнта."
            return
        }

        isValidating = true
        validationError = nil

        Task {
            // Directory mode: check for duplicate host before validating
            if !isOnboarding && !isEditing, let store = providerStore {
                let hostExists = await store.providerHostExists(trimmedEndpoint)
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

            let client = AIClient(endpoint: trimmedEndpoint, apiKey: keyToUse, modelName: "")
            do {
                try await client.validateProvider()

                let provisional = AIProvider(
                    id: editingProvider?.id ?? UUID(),
                    name: providerName.trimmingCharacters(in: .whitespaces),
                    endpoint: trimmedEndpoint,
                    keys: editingProvider?.keys ?? [],
                    models: editingProvider?.models ?? []
                )

                await MainActor.run {
                    isValidating = false
                    validatedProvider = provisional
                    withAnimation { step = .models }
                    fetchModels()
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
            AIProvider(id: $0.id, name: $0.name, endpoint: endpoint.trimmingCharacters(in: .whitespaces), keys: $0.keys, models: $0.models)
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

            let client = AIClient(endpoint: provider.endpoint, apiKey: keyToUse, modelName: "")
            let models = await client.fetchAvailableModels()

            await MainActor.run {
                isFetchingModels = false
                if models.isEmpty {
                    fetchError = "Не удалось загрузить список моделей. Добавьте модели вручную."
                } else {
                    fetchedModels = models
                    fetchError = nil
                    if selectedModels.isEmpty {
                        selectedModels = Set(models)
                    }
                }
            }
        }
    }

    // MARK: - Step 2: Manual Model

    private func addManualModel() {
        let trimmed = manualModelInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !fetchedModels.contains(trimmed) {
            fetchedModels.insert(trimmed, at: 0)
        }
        selectedModels.insert(trimmed)
        manualModelInput = ""
    }

    // MARK: - Step 2: Save Provider

    private func saveProvider() {
        guard let store = providerStore,
              let provisional = validatedProvider ?? editingProvider else { return }

        isSaving = true
        saveError = nil

        let modelsToSave = Array(selectedModels).sorted()

        Task {
            do {
                var finalProvider = provisional
                finalProvider.models = modelsToSave

                if isEditing {
                    try await store.updateProvider(finalProvider)

                    let trimmedKeyValue = apiKeyValue.trimmingCharacters(in: .whitespaces)
                    let resolvedKeyName = apiKeyName.trimmingCharacters(in: .whitespaces)

                    if !trimmedKeyValue.isEmpty, let firstKey = finalProvider.keys.first {
                        var updatedKey = firstKey
                        if !resolvedKeyName.isEmpty { updatedKey.name = resolvedKeyName }
                        try await store.updateKey(updatedKey, newValue: trimmedKeyValue, forProviderId: finalProvider.id)
                    } else if !resolvedKeyName.isEmpty, let firstKey = finalProvider.keys.first {
                        var updatedKey = firstKey
                        updatedKey.name = resolvedKeyName
                        try await store.updateKey(updatedKey, newValue: nil, forProviderId: finalProvider.id)
                    }

                } else if isOnboarding {
                    // Onboarding: merge provider + all pending keys
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

                    // Merge with first key — creates or updates provider
                    let providerId = try await store.mergeProvider(
                        finalProvider,
                        keyName: firstKey.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Default" : firstKey.name,
                        keyValue: firstKey.value.trimmingCharacters(in: .whitespaces),
                        models: modelsToSave
                    )

                    // Merge remaining keys one by one
                    for key in validKeys.dropFirst() {
                        let name = key.name.trimmingCharacters(in: .whitespaces)
                        let value = key.value.trimmingCharacters(in: .whitespaces)
                        _ = try await store.mergeProvider(
                            AIProvider(id: providerId, name: finalProvider.name, endpoint: finalProvider.endpoint),
                            keyName: name.isEmpty ? "Key" : name,
                            keyValue: value,
                            models: [] // models already added on first merge
                        )
                    }

                } else {
                    // Directory: strict add — duplicate host already checked in validateAndProceed
                    let trimmedKeyValue = apiKeyValue.trimmingCharacters(in: .whitespaces)
                    let resolvedKeyName = apiKeyName.trimmingCharacters(in: .whitespaces)

                    // Check key value uniqueness — requires knowing provider id first.
                    // For a new provider there are no existing keys, so no duplicate possible.
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

/// One key row in the onboarding multi-key list.
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

    let model: String
    let isSelected: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))

                Text(model)
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
