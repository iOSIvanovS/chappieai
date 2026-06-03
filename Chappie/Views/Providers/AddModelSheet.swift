// AddModelSheet.swift
// Chappie
//
// Reusable sheet for adding models to a provider.
// Used in: ProviderDetailView (settings), AddProviderSheet step 2.
//
// FLOW:
//   1. Sheet opens — auto-fetches model list from provider endpoint.
//   2. User selects from the list and/or types names manually.
//   3. On confirm — returns the set of selected model names to the caller.
//      Caller is responsible for deduplication against existing models.
//
// DEDUPLICATION:
//   existingModels are shown in the list as already-added (greyed out, not selectable).
//   Only new models can be selected and returned.
//
// MANUAL INPUT:
//   User can type any name and add it — it appears at the top of the list as a custom entry.
//   Manual entries can be selected/deselected like fetched ones.

import SwiftUI
import ChappieCore

// MARK: - AddModelSheet

struct AddModelSheet: View {

    // MARK: - Input

    let provider: AIProvider
    let existingModels: [String]       // Already added models — shown greyed out
    let providerStore: AIProviderStore?
    let onSaved: ([String]) -> Void    // Called with the list of NEW models to add
    let onCancel: () -> Void

    // MARK: - State

    @State private var fetchedModels: [String] = []
    @State private var manualModels: [String] = []  // User-typed entries not in fetched list
    @State private var selectedModels: Set<String> = []
    @State private var manualInput: String = ""
    @State private var searchText: String = ""
    @State private var isFetching: Bool = false
    @State private var fetchError: String? = nil
    @State private var isSaving: Bool = false
    @State private var saveError: String? = nil

    // MARK: - Computed

    /// All available models: manual entries first, then fetched.
    private var allModels: [String] {
        var result = manualModels
        for m in fetchedModels where !result.contains(m) {
            result.append(m)
        }
        return result
    }

    /// Filtered by search text, excluding already-existing models from the selectable pool.
    private var filteredModels: [String] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allModels }
        return allModels.filter { $0.lowercased().contains(q) }
    }

    private var canSave: Bool { !selectedModels.isEmpty }

    private var allFilteredSelected: Bool {
        let selectable = filteredModels.filter { !existingModels.contains($0) }
        return !selectable.isEmpty && selectable.allSatisfy { selectedModels.contains($0) }
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

            // Fetch controls
            HStack(spacing: 12) {
                Button {
                    fetchModels()
                } label: {
                    HStack(spacing: 6) {
                        if isFetching {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(isFetching ? "Загружаем..." : "Загрузить список")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isFetching)

                if !allModels.isEmpty {
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

            if let err = fetchError {
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

                // Select all toggle
                Button { toggleSelectAll() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: allFilteredSelected ? "checkmark.square.fill" : "square")
                            .font(.system(size: 14))
                            .foregroundStyle(allFilteredSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                        Text(allFilteredSelected ? "Снять выделение" : "Выбрать все")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        if !searchText.isEmpty {
                            Text("(\(filteredModels.filter { !existingModels.contains($0) }.count) доступных)")
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
                            let isExisting = existingModels.contains(model)
                            let isSelected = selectedModels.contains(model)

                            ModelSelectRow(
                                model: model,
                                isSelected: isSelected,
                                isExisting: isExisting,
                                onToggle: {
                                    guard !isExisting else { return }
                                    if isSelected {
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
                            Text("Добавить (\(selectedModels.count))")
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
        .onAppear { fetchModels() }
    }

    // MARK: - Fetch Models

    private func fetchModels() {
        guard let store = providerStore else { return }
        isFetching = true
        fetchError = nil

        Task {
            // Load the first available key secret to authenticate the request
            let keySecret: String
            if let firstKey = provider.keys.first {
                keySecret = await store.loadApiKey(for: firstKey.id) ?? ""
            } else {
                keySecret = ""
            }

            guard !keySecret.isEmpty else {
                await MainActor.run {
                    isFetching = false
                    fetchError = "Нет ключей для этого провайдера."
                }
                return
            }

            let client = AIClient(endpoint: provider.endpoint, apiKey: keySecret, modelName: "")
            let models = await client.fetchAvailableModels()

            await MainActor.run {
                isFetching = false
                if models.isEmpty {
                    fetchError = "Не удалось загрузить список. Добавьте модели вручную."
                } else {
                    fetchedModels = models
                    fetchError = nil
                    // Auto-select all new (non-existing) models
                    for m in models where !existingModels.contains(m) {
                        selectedModels.insert(m)
                    }
                }
            }
        }
    }

    // MARK: - Manual Add

    private func addManual() {
        let trimmed = manualInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !fetchedModels.contains(trimmed) && !manualModels.contains(trimmed) {
            manualModels.insert(trimmed, at: 0)
        }
        // Auto-select the manually added model (unless it already exists)
        if !existingModels.contains(trimmed) {
            selectedModels.insert(trimmed)
        }
        manualInput = ""
    }

    // MARK: - Select All Toggle

    private func toggleSelectAll() {
        let selectable = filteredModels.filter { !existingModels.contains($0) }
        if allFilteredSelected {
            for m in selectable { selectedModels.remove(m) }
        } else {
            for m in selectable { selectedModels.insert(m) }
        }
    }

    // MARK: - Confirm

    private func confirmSave() {
        // Filter out any that somehow ended up in existingModels
        let newModels = Array(selectedModels).filter { !existingModels.contains($0) }.sorted()
        guard !newModels.isEmpty else { return }
        onSaved(newModels)
    }
}

// MARK: - ModelSelectRow

private struct ModelSelectRow: View {

    let model: String
    let isSelected: Bool
    let isExisting: Bool   // Already added — greyed out, not selectable
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

                Text(model)
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
