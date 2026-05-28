// ThreadSettingsSheet.swift
// Chappie
//
// Sheet for editing per-thread settings.
// Opened from two places: gear icon in ThreadRowView (sidebar) and gear chip in ProjectChipsView.
//
// ARCHITECTURE (DUMB COMPONENT PRINCIPLE):
// Receives ThreadMetadata + ThreadSettings, returns via onSave(ThreadSettings).
// No direct dependency on ViewModel or SwiftData.
//
// SETTINGS:
// - Thread name (inline rename)
// - Context depth: slider 10...1000 messages
//   Token budget = messages × 500 (displayed as info, not editable)
// - Unlimited context toggle: bypasses all trimming
//
// CONTEXT DEPTH DISPLAY:
// Shows both message count and token budget so the user understands the tradeoff.

import SwiftUI
import ChappieCore

// MARK: - ThreadSettingsSheet

struct ThreadSettingsSheet: View {

    // MARK: - Input

    let thread: ThreadMetadata
    let onSave: (String, ThreadSettings) -> Void
    let onDismiss: () -> Void

    // MARK: - Local draft state

    @State private var draftTitle: String
    @State private var draftSettings: ThreadSettings

    // MARK: - Init

    init(
        thread: ThreadMetadata,
        onSave: @escaping (String, ThreadSettings) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.thread = thread
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
        .frame(width: 440)
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
                // Thread name shown in subtitle — updated live as user types
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

            // Info box — always visible, adapts to current state
            contextInfoBox
        }
    }

    // MARK: - Limited Context Controls

    private var limitedContextControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Message count label
            HStack {
                Text("Сообщений в контексте:")
                    .font(.callout)
                Spacer()
                Text("\(draftSettings.maxMessagesInContext)")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .frame(minWidth: 44, alignment: .trailing)
            }

            // Slider 10...1000 with logarithmic feel via step groups
            Slider(
                value: Binding(
                    get: { Double(draftSettings.maxMessagesInContext) },
                    set: { draftSettings.maxMessagesInContext = Int($0) }
                ),
                in: 10...1000,
                step: sliderStep(for: draftSettings.maxMessagesInContext)
            )
            .accentColor(Color.accentColor)

            // Range labels
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

    /// Shows token budget and chat display depth.
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
                onSave(finalTitle, draftSettings)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(16)
    }

    // MARK: - Helpers

    /// Section label with icon — consistent with ProjectSettingsSheet style.
    private func sectionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
    }

    /// One info row inside the context info box.
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

    /// Formats large numbers with thousands separator for readability.
    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.locale = Locale(identifier: "ru_RU")
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// Returns a slider step that gives finer control at low values, coarser at high.
    /// 10-100: step 5 | 100-500: step 10 | 500-1000: step 50
    private func sliderStep(for value: Int) -> Double {
        switch value {
        case ..<100: return 5
        case ..<500: return 10
        default: return 50
        }
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
        onSave: { title, settings in
            print("Save: \(title), context: \(settings.maxMessagesInContext), unlimited: \(settings.isUnlimitedContext)")
        },
        onDismiss: {}
    )
}

#Preview("Unlimited context") {
    ThreadSettingsSheet(
        thread: ThreadMetadata(
            id: UUID(),
            title: "Без ограничений",
            settings: ThreadSettings(maxMessagesInContext: 100, isUnlimitedContext: true),
            projectIds: [],
            createdAt: Date(),
            updatedAt: Date()
        ),
        onSave: { _, _ in },
        onDismiss: {}
    )
}
