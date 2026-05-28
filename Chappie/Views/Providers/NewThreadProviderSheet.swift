// NewThreadProviderSheet.swift
// Chappie
//
// Sheet shown when creating a new thread.
//
// LEVEL 1 — Provider selection:
//   List of all configured providers. User picks one.
//
// LEVEL 2 — Model selection:
//   List of models saved for the selected provider.
//   User picks one (or types manually if list is empty).
//
// LEVEL 3 — Thread setup (IT-12):
//   Thread name, context depth slider, unlimited context toggle.
//   Mirrors ThreadSettingsSheet controls so the user configures everything upfront.
//
// On confirm → passes (providerId, modelName, threadTitle, ThreadSettings) to ViewModel.
// On cancel → the pending thread is deleted.

import SwiftUI
import ChappieCore

// MARK: - NewThreadProviderSheet

struct NewThreadProviderSheet: View {

    // MARK: - Input

    let providers: [AIProvider]
    let currentProvider: AIProvider?
    let currentModelName: String?
    let onConfirm: (UUID, String, String, ThreadSettings) -> Void
    let onCancel: () -> Void

    // MARK: - State

    @State private var selectedProviderId: UUID?
    @State private var selectedModelName: String = ""
    @State private var manualModelInput: String = ""

    // Thread name + context settings (IT-12)
    @State private var threadTitle: String = ""
    @State private var draftSettings: ThreadSettings = ThreadSettings()

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
                    Text("Выберите провайдера, модель и настройте тред")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            // Provider + Model picker (two-column layout)
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
            .frame(height: 220)

            Divider()

            // IT-12: Thread name + context settings
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    threadNameSection
                    Divider()
                    contextSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .frame(height: 220)

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
                    guard let id = selectedProviderId, !selectedModelName.isEmpty else { return }
                    let title = threadTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    let finalTitle = title.isEmpty ? "Новый тред" : title
                    onConfirm(id, selectedModelName, finalTitle, draftSettings)
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
        .frame(width: 520)
        .onAppear {
            let preselectedProvider = currentProvider ?? providers.first
            selectedProviderId = preselectedProvider?.id
            selectedModelName = currentModelName
                ?? preselectedProvider?.models.first
                ?? ""
        }
    }

    // MARK: - Thread Name Section

    private var threadNameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Название треда", systemImage: "pencil")
                .font(.system(size: 13, weight: .semibold))

            TextField("Новый тред", text: $threadTitle)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
        }
    }

    // MARK: - Context Section

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Глубина контекста", systemImage: "clock.arrow.circlepath")
                .font(.system(size: 13, weight: .semibold))

            // Unlimited context toggle
            Toggle(isOn: $draftSettings.isUnlimitedContext) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Без ограничений")
                        .font(.callout)
                    Text("Все сообщения треда передаются в запросе. Может сильно увеличить стоимость.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            if !draftSettings.isUnlimitedContext {
                limitedContextControls
            }

            contextInfoBox
        }
    }

    // MARK: - Limited Context Controls

    private var limitedContextControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Сообщений в контексте:")
                    .font(.callout)
                Spacer()
                Text("\(draftSettings.maxMessagesInContext)")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .frame(minWidth: 44, alignment: .trailing)
            }

            Slider(
                value: Binding(
                    get: { Double(draftSettings.maxMessagesInContext) },
                    set: { draftSettings.maxMessagesInContext = Int($0) }
                ),
                in: 10...1000,
                step: sliderStep(for: draftSettings.maxMessagesInContext)
            )
            .accentColor(Color.accentColor)

            HStack {
                Text("10")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("1 000")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Context Info Box

    private var contextInfoBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            if draftSettings.isUnlimitedContext {
                infoRow(icon: "infinity", color: .orange, text: "Контекст не ограничен — все сообщения передаются в запросе")
                infoRow(icon: "bubble.left.and.bubble.right", color: .secondary, text: "В чате отображаются все сообщения")
            } else {
                let tokenBudget = draftSettings.maxMessagesInContext * 500
                let chatDepth = draftSettings.maxMessagesInContext * 10
                infoRow(icon: "arrow.up.doc", color: .accentColor, text: "Токен-бюджет запроса: ~\(formatNumber(tokenBudget)) токенов")
                infoRow(icon: "bubble.left.and.bubble.right", color: .secondary, text: "В чате отображается: \(formatNumber(chatDepth)) сообщений")
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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

    // MARK: - Helpers

    private func applyManualModel() {
        let trimmed = manualModelInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        selectedModelName = trimmed
        manualModelInput = ""
    }

    private func infoRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 14)
                .padding(.top, 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.locale = Locale(identifier: "ru_RU")
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func sliderStep(for value: Int) -> Double {
        switch value {
        case ..<100: return 5
        case ..<500: return 10
        default: return 50
        }
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
        onConfirm: { _, _, title, settings in
            print("Confirm: \(title), context: \(settings.maxMessagesInContext)")
        },
        onCancel: {}
    )
}
