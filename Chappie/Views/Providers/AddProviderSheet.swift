// AddProviderSheet.swift
// Chappie
//
// IT-10: Sheet for adding or editing an AI provider.
//
// FLOW (Add):
// Step 1: Enter endpoint URL
// Step 2: Enter API key → fetch available models (GET /v1/models)
//         If fetch fails → allow manual model name input
// Step 3: Select or type model name
// Step 4: Validate connection (test request) → on success: save
//
// FLOW (Edit):
// Pre-fills all fields. API key field shows placeholder (existing key preserved if left empty).
// Same validation before saving.

import SwiftUI
import ChappieCore

// MARK: - AddProviderSheet

struct AddProviderSheet: View {

    // MARK: - Dependencies

    let providerStore: AIProviderStore?
    var editingProvider: AIProvider? = nil
    let onSaved: () -> Void
    let onCancel: () -> Void

    // MARK: - Form State

    @State private var endpoint: String = ""
    @State private var apiKey: String = ""
    @State private var modelName: String = ""
    @State private var availableModels: [String] = []

    // MARK: - UI State

    @State private var isFetchingModels: Bool = false
    @State private var isValidating: Bool = false
    @State private var fetchError: String? = nil
    @State private var validationError: String? = nil
    @State private var showKeyField: Bool = false
    @State private var isKeyVisible: Bool = false
    @State private var modelInputMode: ModelInputMode = .picker // picker or manual

    private enum ModelInputMode { case picker, manual }

    // MARK: - Computed

    private var isEditing: Bool { editingProvider != nil }
    private var title: String { isEditing ? "Редактировать провайдера" : "Добавить провайдера" }

    private var canFetchModels: Bool {
        !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canValidate: Bool {
        !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {
                Image(systemName: isEditing ? "pencil.circle" : "plus.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title2.bold())
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

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // MARK: Endpoint
                    fieldSection(
                        label: "Эндпойнт",
                        icon: "link",
                        hint: "Полный URL, например: https://api.aitunnel.ru/v1/chat/completions"
                    ) {
                        TextField("https://...", text: $endpoint)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }

                    // MARK: API Key
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

                            Button {
                                isKeyVisible.toggle()
                            } label: {
                                Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // MARK: Fetch Models Button
                    HStack {
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
                        .disabled(!canFetchModels || isFetchingModels)

                        if !availableModels.isEmpty {
                            Text("\(availableModels.count) моделей найдено")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }

                    if let fetchErr = fetchError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(fetchErr)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    // MARK: Model Selection
                    fieldSection(
                        label: "Модель",
                        icon: "cpu",
                        hint: availableModels.isEmpty ? "Введите название модели вручную" : "Выберите из списка или введите вручную"
                    ) {
                        if !availableModels.isEmpty {
                            // Segmented picker: list or manual
                            Picker("", selection: $modelInputMode) {
                                Text("Из списка").tag(ModelInputMode.picker)
                                Text("Вручную").tag(ModelInputMode.manual)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 200)

                            if modelInputMode == .picker {
                                Picker("Модель", selection: $modelName) {
                                    Text("Выберите модель").tag("")
                                    ForEach(availableModels, id: \.self) { model in
                                        Text(model).tag(model)
                                    }
                                }
                                .pickerStyle(.menu)
                            } else {
                                TextField("claude-sonnet-4.6", text: $modelName)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                            }
                        } else {
                            TextField("claude-sonnet-4.6", text: $modelName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }
                    }

                    // MARK: Validation Error
                    if let valErr = validationError {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text(valErr)
                                .font(.subheadline)
                                .foregroundStyle(.red)
                        }
                        .padding(12)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(24)
            }

            Divider()

            // Footer
            HStack {
                Spacer()

                Button("Отмена", action: onCancel)
                    .keyboardShortcut(.escape)

                Button {
                    validateAndSave()
                } label: {
                    HStack(spacing: 6) {
                        if isValidating {
                            ProgressView().controlSize(.small)
                            Text("Проверяем...")
                        } else {
                            Text(isEditing ? "Сохранить" : "Добавить")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canValidate || isValidating)
                .keyboardShortcut(.return)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 520, height: 500)
        .onAppear { prefillIfEditing() }
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
            Label(label, systemImage: icon)
                .font(.headline)

            content()

            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func prefillIfEditing() {
        guard let provider = editingProvider else { return }
        endpoint = provider.endpoint
        modelName = provider.modelName
        availableModels = provider.availableModels
        if !provider.availableModels.isEmpty {
            modelInputMode = .picker
        }
        // Don't pre-fill apiKey — user must re-enter or leave blank to keep existing
    }

    private func fetchModels() {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEndpoint.isEmpty, !trimmedKey.isEmpty else { return }

        isFetchingModels = true
        fetchError = nil

        Task {
            let client = AIClient(endpoint: trimmedEndpoint, apiKey: trimmedKey, modelName: "")
            let models = await client.fetchAvailableModels()

            await MainActor.run {
                isFetchingModels = false
                if models.isEmpty {
                    fetchError = "Не удалось загрузить список моделей. Проверьте эндпойнт и ключ, или введите название модели вручную."
                } else {
                    availableModels = models
                    fetchError = nil
                    modelInputMode = .picker
                    // Auto-select first model if none selected
                    if modelName.isEmpty {
                        modelName = models.first ?? ""
                    }
                }
            }
        }
    }

    private func validateAndSave() {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedEndpoint.isEmpty, !trimmedModel.isEmpty else { return }

        // For editing: if key is empty, we need the existing key from Keychain
        let keyToUse: String
        if isEditing && trimmedKey.isEmpty {
            // Keep existing key — pass nil to updateProvider
            keyToUse = ""
        } else {
            keyToUse = trimmedKey
        }

        guard !keyToUse.isEmpty || (isEditing && trimmedKey.isEmpty) else { return }

        isValidating = true
        validationError = nil

        Task {
            // For validation, use existing key if editing and no new key provided
            let validationKey: String
            if isEditing && trimmedKey.isEmpty, let existingProvider = editingProvider,
               let store = providerStore {
                validationKey = await store.loadApiKey(for: existingProvider.id) ?? ""
            } else {
                validationKey = trimmedKey
            }

            let client = AIClient(endpoint: trimmedEndpoint, apiKey: validationKey, modelName: trimmedModel)

            do {
                try await client.validateConnection()

                // Save to store
                await saveProvider(
                    endpoint: trimmedEndpoint,
                    apiKey: isEditing && trimmedKey.isEmpty ? nil : trimmedKey,
                    modelName: trimmedModel
                )

            } catch {
                await MainActor.run {
                    isValidating = false
                    validationError = "Ошибка подключения: \(error.localizedDescription)\n\nПроверьте эндпойнт, ключ и название модели."
                }
            }
        }
    }

    private func saveProvider(endpoint: String, apiKey: String?, modelName: String) async {
        guard let store = providerStore else { return }

        do {
            if let existing = editingProvider {
                // Update existing provider
                var updated = existing
                updated.endpoint = endpoint
                updated.modelName = modelName
                updated.availableModels = availableModels
                try await store.updateProvider(updated, apiKey: apiKey)
            } else {
                // Add new provider
                let newProvider = AIProvider(
                    endpoint: endpoint,
                    modelName: modelName,
                    availableModels: availableModels
                )
                try await store.addProvider(newProvider, apiKey: apiKey ?? "")
            }

            await MainActor.run {
                isValidating = false
                onSaved()
            }
        } catch {
            await MainActor.run {
                isValidating = false
                validationError = "Ошибка сохранения: \(error.localizedDescription)"
            }
        }
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
