// NewThreadProviderSheet.swift
// Chappie
//
// Two-level picker shown when creating a new thread.
//
// LEVEL 1 — Provider selection:
//   List of all configured providers. User picks one.
//
// LEVEL 2 — Model selection:
//   List of models saved for the selected provider.
//   User picks one (or types manually if list is empty).
//
// On confirm → passes (providerId, modelName) to ViewModel.
// On cancel → the pending thread is deleted.

import SwiftUI
import ChappieCore

// MARK: - NewThreadProviderSheet

struct NewThreadProviderSheet: View {

    // MARK: - Input

    let providers: [AIProvider]
    let currentProvider: AIProvider?
    let currentModelName: String?
    let onConfirm: (UUID, String) -> Void
    let onCancel: () -> Void

    // MARK: - State

    @State private var selectedProviderId: UUID?
    @State private var selectedModelName: String = ""
    @State private var manualModelInput: String = ""

    // MARK: - Computed

    private var selectedProvider: AIProvider? {
        providers.first { $0.id == selectedProviderId }
    }

    private var canConfirm: Bool {
        selectedProviderId != nil && !selectedModelName.isEmpty
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {
                Image(systemName: "plus.bubble")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Новый тред")
                        .font(.title2.bold())
                    Text("Выберите провайдера и модель")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            HStack(alignment: .top, spacing: 0) {

                // Left column: providers
                VStack(alignment: .leading, spacing: 0) {
                    Text("Провайдер")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 6)

                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(providers) { provider in
                                ProviderPickRow(
                                    provider: provider,
                                    isSelected: selectedProviderId == provider.id,
                                    onSelect: {
                                        selectedProviderId = provider.id
                                        // Auto-select first model of this provider
                                        selectedModelName = provider.models.first ?? ""
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                }
                .frame(width: 200)

                Divider()

                // Right column: models
                VStack(alignment: .leading, spacing: 0) {
                    Text("Модель")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 6)

                    if let provider = selectedProvider {
                        if provider.models.isEmpty {
                            modelsEmptyState
                        } else {
                            ScrollView {
                                VStack(spacing: 2) {
                                    ForEach(provider.models, id: \.self) { model in
                                        ModelPickRow(
                                            model: model,
                                            isSelected: selectedModelName == model,
                                            onSelect: { selectedModelName = model }
                                        )
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.bottom, 8)
                            }
                        }

                        // Manual input always available
                        Divider()
                        HStack(spacing: 6) {
                            TextField("Ввести вручную…", text: $manualModelInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .onSubmit { applyManualModel() }
                            Button("OK") { applyManualModel() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(manualModelInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                    } else {
                        // No provider selected yet
                        VStack {
                            Spacer()
                            Text("← Выберите провайдера")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 280)

            Divider()

            // Footer
            HStack {
                Button("Отмена", action: onCancel)
                    .keyboardShortcut(.escape)

                Spacer()

                // Show selected summary
                if let provider = selectedProvider, !selectedModelName.isEmpty {
                    Text("\(provider.displayName) · \(selectedModelName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Button {
                    if let id = selectedProviderId, !selectedModelName.isEmpty {
                        onConfirm(id, selectedModelName)
                    }
                } label: {
                    Text("Начать")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canConfirm)
                .keyboardShortcut(.return)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 480)
        .onAppear {
            let preselectedProvider = currentProvider ?? providers.first
            selectedProviderId = preselectedProvider?.id
            selectedModelName = currentModelName
                ?? preselectedProvider?.models.first
                ?? ""
        }
    }

    // MARK: - Models Empty State

    private var modelsEmptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 28))
                .foregroundStyle(.secondary.opacity(0.4))
            Text("Нет сохранённых моделей")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Введите название вручную")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Manual Model

    private func applyManualModel() {
        let trimmed = manualModelInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        selectedModelName = trimmed
        manualModelInput = ""
    }
}

// MARK: - ProviderPickRow

private struct ProviderPickRow: View {

    let provider: AIProvider
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.3))

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(provider.displayHost)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.1)
                          : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - ModelPickRow

private struct ModelPickRow: View {

    let model: String
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.3))

                // weight before design — correct argument order for .system()
                Text(model)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.1)
                          : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Preview

#Preview {
    NewThreadProviderSheet(
        providers: [
            AIProvider(
                id: UUID(),
                name: "AITunnel",
                endpoint: "https://api.aitunnel.ru/v1/chat/completions",
                models: ["claude-sonnet-4-5", "gpt-4o", "gemini-1.5-pro"]
            ),
            AIProvider(
                id: UUID(),
                name: "Local Ollama",
                endpoint: "http://localhost:11434/v1/chat/completions",
                models: ["llama3.2", "mistral"]
            )
        ],
        currentProvider: nil,
        currentModelName: nil,
        onConfirm: { _, _ in },
        onCancel: {}
    )
}
