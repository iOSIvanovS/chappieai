// NewThreadProviderSheet.swift
// Chappie
//
// Sheet shown when creating a new thread.
//
// LEVEL 1 — Provider selection:
//   List of all configured providers. User picks one.
//
// LEVEL 2 — Key + Model selection:
//   Keys saved for the selected provider — user picks one (Variant B: picker under provider).
//   Models saved for the selected provider — user picks one.
//   Manual model input available if list is empty.
//
// LEVEL 3 — Thread setup:
//   Thread name, context depth slider, unlimited context toggle.
//
// On confirm → passes (providerId, keyId, modelName, threadTitle, ThreadSettings) to ViewModel.
// On cancel → the pending thread is deleted.
//
// POLICY: no auto-selection of key or model. User must pick explicitly.
// canConfirm requires provider + key + model before "Начать" is enabled.
//
// NOTE MK-07: Key picker is shown here but key selection UI is minimal until
// MK-07 full implementation. For providers with a single key it auto-selects.

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
        selectedProviderId != nil && selectedKeyId != nil && !selectedModelName.isEmpty
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
                    Text("Выберите провайдера, ключ, модель и настройте тред")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            // Provider + Key + Model picker
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
                                        // Auto-select key if provider has exactly one
                                        selectedKeyId = provider.keys.count == 1 ? provider.keys.first?.id : nil
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                }
                .frame(width: 180)

                Divider()

                // Middle column: keys
                VStack(alignment: .leading, spacing: 0) {
                    Text("Ключ")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 6)

                    if let provider = selectedProvider {
                        if provider.keys.isEmpty {
                            keysEmptyState
                        } else {
                            ScrollView {
                                VStack(spacing: 2) {
                                    ForEach(provider.keys) { key in
                                        KeyPickRow(
                                            key: key,
                                            isSelected: selectedKeyId == key.id,
                                            onSelect: { selectedKeyId = key.id }
                                        )
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.bottom, 8)
                            }
                        }
                    } else {
                        noProviderHint
                    }
                }
                .frame(width: 160)

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
                    if !selectedModelName.isEmpty, let keyId = selectedKeyId,
                       let key = provider.keys.first(where: { $0.id == keyId }) {
                        Text("\(provider.displayName) · \(key.name) · \(selectedModelName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if selectedKeyId == nil {
                        Text("Выберите ключ")
                            .font(.caption)
                            .foregroundStyle(.orange)
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
        .frame(width: 560)
        .onAppear {
            let preselectedProvider = currentProvider ?? providers.first
            selectedProviderId = preselectedProvider?.id
            // Auto-select key if provider has exactly one
            if let provider = preselectedProvider {
                selectedKeyId = provider.keys.count == 1 ? provider.keys.first?.id : nil
            }
            // Restore current model only if still valid
            if let model = currentModelName,
               let provider = preselectedProvider,
               provider.models.contains(model) {
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
                Text("10").font(.caption2).foregroundStyle(.secondary)
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
                let chatDepth = draftSettings.maxMessagesInContext * 10
                infoRow(icon: "arrow.up.doc", color: .accentColor, text: "Токен-бюджет запроса: ~\(formatNumber(tokenBudget)) токенов")
                infoRow(icon: "bubble.left.and.bubble.right", color: .secondary, text: "В чате отображается: \(formatNumber(chatDepth)) сообщений")
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Empty States

    private var keysEmptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "key.slash")
                .font(.system(size: 24))
                .foregroundStyle(.secondary.opacity(0.4))
            Text("Нет ключей")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

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

    private func sliderStep(for value: Int) -> Double {
        switch value {
        case ..<100: return 5
        case ..<500: return 10
        default: return 50
        }
    }
}

// MARK: - KeyPickRow

private struct KeyPickRow: View {

    let key: APIKey
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 16)

                Text(key.name)
                    .font(.system(size: 12))
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
    NewThreadProviderSheet(
        providers: [
            AIProvider(
                id: UUID(),
                name: "AITunnel",
                endpoint: "https://api.aitunnel.ru/v1/chat/completions",
                keys: [APIKey(name: "Рабочий"), APIKey(name: "Личный")],
                models: ["claude-sonnet-4-5", "gpt-4o"]
            )
        ],
        currentProvider: nil,
        currentModelName: nil,
        onConfirm: { _, _, _, title, settings in
            print("Confirm: \(title)")
        },
        onCancel: {}
    )
}
