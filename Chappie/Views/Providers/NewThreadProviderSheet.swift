// NewThreadProviderSheet.swift
// Chappie
//
// Sheet shown when creating a new thread.
//
// LEVEL 1 — Provider selection:
//   List of all configured providers. User picks one.
//   Auto-selects first key if provider has keys.
//
// LEVEL 2 — Model selection:
//   Models saved for the selected provider — user picks one.
//   Manual model input available if list is empty.
//
// LEVEL 3 — Thread setup:
//   Thread name, context depth slider, unlimited context toggle.
//
// KEY POLICY:
//   Key selection moved to ThreadSettingsSheet.
//   Here we auto-select first key of the chosen provider (or nil for keyless providers).
//   canConfirm requires provider + model. Key is auto-resolved.
//
// On confirm → passes (providerId, keyId, modelName, threadTitle, ThreadSettings) to ViewModel.
// On cancel → the pending thread is deleted.

import SwiftUI
import ChappieCore

// MARK: - NewThreadProviderSheet

struct NewThreadProviderSheet: View {

    // MARK: - Input

    let providers: [AIProvider]
    let currentProvider: AIProvider?
    let currentModelName: String?
    let onConfirm: (UUID, UUID?, String, String, ThreadSettings) -> Void
    let onCancel: () -> Void

    // MARK: - State

    @State private var selectedProviderId: UUID?
    @State private var selectedKeyId: UUID?
    @State private var selectedModelName: String = ""
    @State private var manualModelInput: String = ""

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

            // Provider + Model picker
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
                                        selectedModelName = ""
                                        // Auto-select first key (or nil for keyless providers)
                                        selectedKeyId = provider.requiresApiKey
                                            ? provider.keys.first?.id
                                            : nil
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
                                    ForEach(provider.models) { model in
                                        ModelPickRow(
                                            model: model.id,
                                            isSelected: selectedModelName == model.id,
                                            onSelect: { selectedModelName = model.id }
                                        )
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.bottom, 8)
                            }
                        }

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
                        noProviderHint
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 220)

            Divider()

            // Thread name + context settings
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

                // Selection summary
                if let provider = selectedProvider {
                    if !selectedModelName.isEmpty {
                        Text("\(provider.displayName) · \(selectedModelName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Выберите модель")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Button {
                    guard let id = selectedProviderId, !selectedModelName.isEmpty else { return }
                    let title = threadTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    let finalTitle = title.isEmpty ? "Новый тред" : title
                    onConfirm(id, selectedKeyId, selectedModelName, finalTitle, draftSettings)
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
            // Auto-select first key (or nil for keyless providers like Ollama)
            if let provider = preselectedProvider {
                selectedKeyId = provider.requiresApiKey ? provider.keys.first?.id : nil
            }
            // Restore current model only if still valid
            if let model = currentModelName,
               let provider = preselectedProvider,
               provider.models.contains(where: { $0.id == model }) {
                selectedModelName = model
            }
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

            // Step 100: map slider 1...10 → actual value × 100
            Slider(
                value: Binding(
                    get: { Double(draftSettings.maxMessagesInContext / 100) },
                    set: { draftSettings.maxMessagesInContext = Int($0) * 100 }
                ),
                in: 1...10,
                step: 1
            )
            .accentColor(Color.accentColor)

            HStack {
                Text("100").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("1 000").font(.caption2).foregroundStyle(.secondary)
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
                infoRow(icon: "arrow.up.doc", color: .accentColor, text: "Токен-бюджет запроса: ~\(formatNumber(tokenBudget)) токенов")
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Empty States

    private var modelsEmptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 24))
                .foregroundStyle(.secondary.opacity(0.4))
            Text("Нет моделей")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Введите вручную")
                .font(.caption2)
                .foregroundStyle(.secondary.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var noProviderHint: some View {
        VStack {
            Spacer()
            Text("← Выберите провайдера")
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color).frame(width: 14).padding(.top, 1)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.locale = Locale(identifier: "ru_RU")
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

// MARK: - Preview

#Preview {
    NewThreadProviderSheet(
        providers: [
            AIProvider(
                id: UUID(),
                name: "AITunnel",
                baseURL: "https://api.aitunnel.ru/v1",
                keys: [APIKey(name: "Рабочий"), APIKey(name: "Личный")],
                models: [
                    AIModel(id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5"),
                    AIModel(id: "gpt-4o", name: "GPT-4o")
                ]
            )
        ],
        currentProvider: nil,
        currentModelName: nil,
        onConfirm: { _, _, _, title, _ in
            print("Confirm: \(title)")
        },
        onCancel: {}
    )
}
