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
// - Context depth: slider 100...1000, step 100, default 300
// - Unlimited context toggle
//
// NOTE: Provider + model selection happens ONLY via the "Модель" chip in the chat toolbar.
// Adding/editing/deleting providers happens ONLY in the provider directory (SettingsView).
// This sheet intentionally has no provider picker.

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
                    contextSection
                }
                .padding(20)
            }

            Divider()
            footerView
        }
        .frame(width: 480)
        .frame(minHeight: 320)
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
                Text("100")
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
                infoRow(
                    icon: "arrow.up.doc",
                    color: .accentColor,
                    text: "Токен-бюджет запроса: ~\(formatNumber(tokenBudget)) токенов"
                )
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
                // Pass nil for provider/key/model — this sheet no longer manages them
                onSave(finalTitle, draftSettings, nil, nil, nil)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(16)
    }

    // MARK: - Helpers

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
        providers: [],
        onSave: { title, settings, _, _, _ in
            print("Save: \(title)")
        },
        onDismiss: {}
    )
}
