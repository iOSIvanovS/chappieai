// ThreadSettingsSheet.swift
// Chappie
//
// Sheet for editing per-thread settings.
// Opened from two places: gear icon in ThreadRowView (sidebar) and gear chip in ProjectChipsView.
//
// ARCHITECTURE (DUMB COMPONENT PRINCIPLE):
// Receives ThreadMetadata + available providers, returns via onSave.
// No direct dependency on ViewModel or SwiftData.
//
// SETTINGS:
// - Thread name (inline rename)
// - Provider + key + model (3-column picker, per-thread isolation)
// - Context depth: slider 10...1000 messages
//   Token budget = messages × 500 (displayed as info, not editable)
// - Unlimited context toggle: bypasses all trimming
//
// ProviderPickRow / ModelPickRow are defined in Shared/ProviderModelPickerRows.swift.

import SwiftUI
import ChappieCore

// MARK: - ThreadSettingsSheet

struct ThreadSettingsSheet: View {

    // MARK: - Input

    let thread: ThreadMetadata
    let providers: [AIProvider]
    let onSave: (String, ThreadSettings, UUID?, UUID?, String?) -> Void
    let onDismiss: () -> Void

    // MARK: - Local draft state

    @State private var draftTitle: String
    @State private var draftSettings: ThreadSettings
    @State private var selectedProviderId: UUID?
    @State private var selectedKeyId: UUID?
    @State private var selectedModelName: String
    @State private var manualModelInput: String = ""

    // MARK: - Computed

    private var selectedProvider: AIProvider? {
        providers.first { $0.id == selectedProviderId }
    }

    // MARK: - Init

    init(
        thread: ThreadMetadata,
        providers: [AIProvider],
        onSave: @escaping (String, ThreadSettings, UUID?, UUID?, String?) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.thread = thread
        self.providers = providers
        self.onSave = onSave
        self.onDismiss = onDismiss
        self._draftTitle = State(initialValue: thread.title)
        self._draftSettings = State(initialValue: thread.settings)
        self._selectedProviderId = State(initialValue: thread.settings.activeProviderId)
        self._selectedKeyId = State(initialValue: thread.settings.activeKeyId)
        self._selectedModelName = State(initialValue: thread.settings.activeModelName ?? "")
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    nameSection
                    Divider().padding(.vertical, 2)
                    if !providers.isEmpty {
                        providerSection
                        Divider().padding(.vertical, 2)
                    }
                    contextSection
                }
                .padding(20)
            }

            Divider()
            footerView
        }
        .frame(width: 520)
        .frame(minHeight: 400)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 10) {
            Image(systemName: "gear")
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Настройки треда")
                    .font(.headline)
                Text(draftTitle.isEmpty ? "Без названия" : draftTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    // MARK: - Name Section

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Название треда", systemImage: "pencil")

            TextField("Название треда", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
        }
    }

    // MARK: - Provider Section (3-column: provider / key / model)

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Провайдер и модель", systemImage: "cpu")

            HStack(alignment: .top, spacing: 0) {

                // Left: providers
                VStack(alignment: .leading, spacing: 0) {
                    Text("Провайдер")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)

                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(providers) { provider in
                                ProviderPickRow(
                                    provider: provider,
                                    isSelected: selectedProviderId == provider.id,
                                    onSelect: {
                                        selectedProviderId = provider.id
                                        // Auto-select key if provider has exactly one
                                        selectedKeyId = provider.keys.count == 1 ? provider.keys.first?.id : nil
                                        selectedModelName = provider.models.first?.id ?? ""
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .frame(maxHeight: 150)
                }
                .frame(width: 160)

                Divider()
                    .padding(.horizontal, 8)

                // Middle: keys
                VStack(alignment: .leading, spacing: 0) {
                    Text("Ключ")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)

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
                                .padding(.horizontal, 4)
                            }
                            .frame(maxHeight: 150)
                        }
                    } else {
                        noProviderHint
                    }
                }
                .frame(width: 140)

                Divider()
                    .padding(.horizontal, 8)

                // Right: models
                VStack(alignment: .leading, spacing: 0) {
                    Text("Модель")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)

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
                                .padding(.horizontal, 4)
                            }
                            .frame(maxHeight: 150)
                        }

                        // Manual model input
                        Divider().padding(.vertical, 4)
                        HStack(spacing: 6) {
                            TextField("Ввести вручную…", text: $manualModelInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.callout, design: .monospaced))
                                .onSubmit { applyManualModel() }
                            Button("OK") { applyManualModel() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(manualModelInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    } else {
                        noProviderHint
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(12)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            selectionSummary
        }
    }

    // MARK: - Selection Summary

    @ViewBuilder
    private var selectionSummary: some View {
        if let provider = selectedProvider {
            if !selectedModelName.isEmpty, let keyId = selectedKeyId,
               let key = provider.keys.first(where: { $0.id == keyId }) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                    Text("\(provider.displayName) · \(key.name) · \(selectedModelName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if selectedKeyId == nil {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text("Выберите ключ")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else if selectedModelName.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text("Выберите модель")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Context Depth Section

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Глубина контекста", systemImage: "clock.arrow.circlepath")

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
                infoRow(
                    icon: "infinity",
                    color: .orange,
                    text: "Контекст не ограничен — все сообщения передаются в запросе"
                )
                infoRow(
                    icon: "bubble.left.and.bubble.right",
                    color: .secondary,
                    text: "В чате отображаются все сообщения"
                )
            } else {
                let tokenBudget = draftSettings.maxMessagesInContext * 500
                let chatDepth = draftSettings.maxMessagesInContext * 10

                infoRow(
                    icon: "arrow.up.doc",
                    color: .accentColor,
                    text: "Токен-бюджет запроса: ~\(formatNumber(tokenBudget)) токенов"
                )
                infoRow(
                    icon: "bubble.left.and.bubble.right",
                    color: .secondary,
                    text: "В чате отображается: \(formatNumber(chatDepth)) сообщений"
                )
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Empty / Hint States

    private var keysEmptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "key.slash")
                .font(.system(size: 20))
                .foregroundStyle(.secondary.opacity(0.4))
            Text("Нет ключей")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: 80)
    }

    private var modelsEmptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 20))
                .foregroundStyle(.secondary.opacity(0.4))
            Text("Нет сохранённых моделей")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: 80)
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

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Button("Отмена") {
                onDismiss()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button("Сохранить") {
                let trimmedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalTitle = trimmedTitle.isEmpty ? thread.title : trimmedTitle
                onSave(
                    finalTitle,
                    draftSettings,
                    selectedProviderId,
                    selectedKeyId,
                    selectedModelName.isEmpty ? nil : selectedModelName
                )
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(16)
    }

    // MARK: - Helpers

    private func applyManualModel() {
        let trimmed = manualModelInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        selectedModelName = trimmed
        manualModelInput = ""
    }

    private func sectionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
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

    private func infoRow(icon: String, color: AnyShapeStyle, text: String) -> some View {
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

#Preview("Default settings") {
    ThreadSettingsSheet(
        thread: ThreadMetadata(
            id: UUID(),
            title: "Разработка Chappie",
            settings: ThreadSettings(),
            projectIds: [],
            createdAt: Date(),
            updatedAt: Date()
        ),
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
        onSave: { title, settings, providerId, keyId, modelName in
            print("Save: \(title), provider: \(String(describing: providerId)), key: \(String(describing: keyId)), model: \(String(describing: modelName))")
        },
        onDismiss: {}
    )
}
