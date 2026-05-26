// SidebarView.swift
// Chappie
//
// НАЗНАЧЕНИЕ:
// Боковая панель приложения — навигация по тредам (IT-05).
//
// АРХИТЕКТУРНЫЕ ИЗМЕНЕНИЯ (IT-05):
// Добавлен список тредов как в Claude/ChatGPT:
// - Секция "Треды" со списком всех тредов (ThreadListView)
// - Кнопка "Новый тред" внизу панели
// - Подсветка активного треда
// - Переименование двойным кликом / контекстным меню
// - Удаление через кнопку hover / контекстное меню
//
// ПРИНЦИП "ТУПОГО КОМПОНЕНТА":
// SidebarView не знает о ThreadStore и SwiftData. Все данные приходят через
// параметры (threads, selectedThreadId), все действия — через коллбэки.
// Бизнес-логика — в ChappieViewModel.

import SwiftUI
import ChappieCore

/// Боковая панель приложения Чаппи.
///
/// Показывает:
/// - список тредов (IT-05)
/// - текущий воркспейс (или кнопку выбора)
/// - предупреждение если API-ключ не задан
/// - кнопку "Новый тред" внизу
struct SidebarView: View {

    // MARK: - Входные данные (состояние)

    /// URL текущего выбранного воркспейса (nil если не выбран)
    let workspaceURL: URL?

    /// Флаг: задан ли валидный API-ключ
    let isApiKeyValid: Bool

    /// Список тредов для отображения (отсортированы по updatedAt DESC)
    let threads: [ThreadMetadata]

    /// UUID активного треда
    let selectedThreadId: UUID?

    // MARK: - Коллбэки действий

    let onSelectWorkspace: () -> Void
    let onOpenSettings: () -> Void
    let onSelectThread: (ThreadMetadata) -> Void
    let onCreateThread: () -> Void
    let onDeleteThread: (ThreadMetadata) -> Void
    let onRenameThread: (ThreadMetadata, String) -> Void

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {

            // MARK: Основной скроллируемый список
            List {

                // Секция тредов — показываем всегда (даже если пустая)
                Section {
                    if threads.isEmpty {
                        // Плейсхолдер когда тредов ещё нет
                        Text("Нет тредов")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                    } else {
                        ThreadListView(
                            threads: threads,
                            selectedThreadId: selectedThreadId,
                            onSelect: onSelectThread,
                            onDelete: onDeleteThread,
                            onRename: onRenameThread
                        )
                        // Убираем стандартные отступы ListRow — ThreadRowView рисует свои
                        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    Text("Треды")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(nil) // Отключаем автоматический uppercase в заголовках секций
                }

                // Секция воркспейса
                workspaceSection

                // Предупреждение об API-ключе (только если не задан)
                if !isApiKeyValid {
                    apiKeyWarningSection
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.sidebar)

            Divider()

            // MARK: Кнопка "Новый тред" внизу панели
            // Закреплена внизу — всегда видна независимо от скролла
            Button(action: onCreateThread) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                    Text("Новый тред")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .background(Color.primary.opacity(0.03))
        }
        .navigationTitle("Чаппи")
    }

    // MARK: - Секция воркспейса

    /// Секция с информацией о текущем воркспейсе.
    private var workspaceSection: some View {
        Section("Контекст") {
            if let workspaceURL = workspaceURL {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Рабочая папка:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(workspaceURL.lastPathComponent)
                        .font(.headline)
                }

                Button("Сменить папку...") {
                    onSelectWorkspace()
                }
                .buttonStyle(.link)
                .padding(.top, 4)

            } else {
                Button("Выбрать папку проекта...") {
                    onSelectWorkspace()
                }
            }
        }
    }

    // MARK: - Секция предупреждения об API-ключе

    /// Секция-предупреждение — показывается только когда ключ не задан.
    private var apiKeyWarningSection: some View {
        Section("⚠️ Внимание") {
            VStack(alignment: .leading, spacing: 8) {
                Text("API-ключ не задан")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)

                Text("Без ключа AITunnel Чаппи не сможет отвечать.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Открыть настройки") {
                    onOpenSettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationSplitView {
        SidebarView(
            workspaceURL: URL(fileURLWithPath: "/Users/sergej/Projects/Chappie"),
            isApiKeyValid: true,
            threads: [
                ThreadMetadata(
                    id: UUID(),
                    title: "Рефакторинг тредов",
                    createdAt: Date().addingTimeInterval(-3600),
                    updatedAt: Date().addingTimeInterval(-600),
                    projectIds: []
                ),
                ThreadMetadata(
                    id: UUID(),
                    title: "Исправление багов SwiftData",
                    createdAt: Date().addingTimeInterval(-7200),
                    updatedAt: Date().addingTimeInterval(-3600),
                    projectIds: []
                )
            ],
            selectedThreadId: nil,
            onSelectWorkspace: {},
            onOpenSettings: {},
            onSelectThread: { _ in },
            onCreateThread: {},
            onDeleteThread: { _ in },
            onRenameThread: { _, _ in }
        )
    } detail: {
        Text("Detail")
    }
}
