// AddProviderSheet.swift
// Chappie
//
// Two-step sheet for adding a new AI provider.
//
// STEP 1 — Provider:
//   Enter endpoint URL, API key, optional name.
//   Validate provider (GET /v1/models — no model name needed).
//   On success → proceed to step 2.
//
// STEP 2 — Models:
//   Fetch available models from the provider (auto-populated if /models works).
//   User can select from the list OR type model names manually.
//   Each added model is saved to provider.models list.
//   Must add at least one model to proceed.
//
// EDIT MODE:
//   Opens directly on step 1 pre-filled with existing data.
//   API key field shows placeholder (existing key preserved if left empty).
//   Models list is editable — add/remove individual models.

import SwiftUI
import ChappieCore

// MARK: - AddProviderSheet

struct AddProviderSheet: View {

    // MARK: - Input

    let providerStore: AIProviderStore?
    var editingProvider: AIProvider? = nil
    let onSaved: () -> Void
    let onCancel: () -> Void

    // MARK: - Step

    private enum Step { case provider, models }
    @State private var step: Step = .provider

    // MARK: - Step 1 State

    @State private var providerName: String = ""
    @State private var endpoint: String = ""
    @State private var apiKey: String = ""
    @State private var isKeyVisible: Bool = false
    @State private var isValidating: Bool = false
    @State private var validationError: String? = nil
    @State private var validatedProvider: AIProvider? = nil // confirmed after step 1

    // MARK: - Step 2 State

    @State private var fetchedModels: [String] = []       // from GET /models
    @State private var selectedModels: Set<String> = []   // checked in the list
    @State private var manualModelInput: String = ""
    @State private var isFetchingModels: Bool = false
    @State private var fetchError: String? = nil
    @State private var isSaving: Bool = false
    @State private var saveError: String? = nil

    // MARK: - Computed

    private var isEditing: Bool { editingProvider != nil }
    private var title: String { isEditing ? "Редактировать провайдера" : "Добавить провайдера" }

    private var canValidate: Bool {
        !endpoint.trimmingCharacters(in: .whitespaces).isEmpty &&
        (!apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isEditing)
    }

    // All models to show in step 2: fetched list + any already saved on the provider
    private var allModels: [String] {
        var combined = fetchedModels
        if let existing = editingProvider {
            for m in existing.models where !combined.contains(m) {
                combined.insert(m, at: 0)
            }
        }
        return combined
    }

    private var canSave: Bool { !selectedModels.isEmpty }

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

            // Step content
            switch step {
            case .provider: providerStep
            case .models:   modelsStep
            }

            Divider()

            // Footer
            footerButtons
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { prefillIfEditing() }
    }

    // MARK: - Step 1: Provider

    private var providerStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Name (optional)
                fieldSection(label: "Название", icon: "tag", hint: "Необязательно. Например: «Work OpenAI» или «Personal Groq»") {
                    TextField("Мой провайдер", text: $providerName)
                        .textFieldStyle(.roundedBorder)
                }

                // Endpoint
                fieldSection(label: "Эндпойнт", icon: "link", hint: "Полный URL, например: https://api.aitunnel.ru/v1/chat/completions") {
                    TextField("https://...", text: $endpoint)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                // API Key
                fieldSection(
                    label: "API-ключ",
                    icon: "key.fill",
                    hint: isEditing ? "Оставьте пустым чтобы сохранить текущий ключ" : "Ключ будет сохранён в системном Keychain"
                ) {
                    HStack(spacing: 8) {
                        Group {
                            if isKeyVisible {
                                TextField(isEditing ? "Новый ключ (необязательно)" : "sk-...", text: $apiKey)
                            } else {
                                SecureField(isEditing ? "Новый ключ (необязательно)" : "sk-...", text: $apiKey)
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

                // Validation error
                if let err = validationError {
                    errorBanner(err)
                }
            }
            .padding(24)
        }
    }

    // MARK: - Step 2: Models

    private var modelsStep: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Fetch button
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
                        Text(isFetchingModels ? "Загружаем модели..." : "Загрузить список моделей")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isFetchingModels)

                if !fetchedModels.isEmpty {
                    Text("\(fetchedModels.count) доступно")
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

            // Models list
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
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(allModels, id: \.self) { model in
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
                .frame(maxHeight: 260)
            }

            Divider()

            // Manual input
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

            // Save error
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
            // Back / Cancel
            Button(step == .provider ? "Отмена" : "Назад") {
                if step == .provider {
                    onCancel()
                } else {
                    withAnimation { step = .provider }
                }
            }
            .keyboardShortcut(.escape)

            Spacer()

            // Primary action
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
        // Pre-select all existing models
        selectedModels = Set(provider.models)
    }

    // MARK: - Step 1: Validate Provider

    private func validateAndProceed() {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespaces)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)

        guard !trimmedEndpoint.isEmpty else {
            validationError = "Введите URL эндпойнта."
            return
        }

        // For editing: if no new key, use existing from Keychain
        isValidating = true
        validationError = nil

        Task {
            let keyToUse: String
            if isEditing && trimmedKey.isEmpty, let existing = editingProvider,
               let store = providerStore {
                keyToUse = await store.loadApiKey(for: existing.id) ?? ""
            } else {
                keyToUse = trimmedKey
            }

            guard !keyToUse.isEmpty else {
                await MainActor.run {
                    isValidating = false
                    validationError = "Введите API-ключ."
                }
                return
            }

            // Validate provider without a model
            let client = AIClient(endpoint: trimmedEndpoint, apiKey: keyToUse, modelName: "")
            do {
                try await client.validateProvider()

                // Build a provisional provider to carry into step 2
                let provisional = AIProvider(
                    id: editingProvider?.id ?? UUID(),
                    name: providerName.trimmingCharacters(in: .whitespaces),
                    endpoint: trimmedEndpoint,
                    models: editingProvider?.models ?? []
                )

                await MainActor.run {
                    isValidating = false
                    validatedProvider = provisional
                    // Kick off model fetch in the background while user sees step 2
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
            AIProvider(id: $0.id, name: $0.name, endpoint: endpoint.trimmingCharacters(in: .whitespaces), models: $0.models)
        }) else { return }

        isFetchingModels = true
        fetchError = nil

        Task {
            let keyToUse: String
            let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)
            if isEditing && trimmedKey.isEmpty, let existing = editingProvider,
               let store = providerStore {
                keyToUse = await store.loadApiKey(for: existing.id) ?? ""
            } else {
                keyToUse = trimmedKey
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
                    // Auto-select all fetched if nothing selected yet
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

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)
        let modelsToSave = Array(selectedModels).sorted()

        Task {
            do {
                var finalProvider = provisional
                finalProvider.models = modelsToSave

                if isEditing {
                    let keyArg: String? = trimmedKey.isEmpty ? nil : trimmedKey
                    try await store.updateProvider(finalProvider, apiKey: keyArg)
                } else {
                    try await store.addProvider(finalProvider, apiKey: trimmedKey)
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
