// ThreadListView.swift
// Chappie
//
// НАЗНАЧЕНИЕ:
// Список тредов в боковой панели — главный навигационный элемент IT-05.
// Классический вид как в Claude/ChatGPT: каждый тред — строка с названием и датой.
//
// АРХИТЕКТУРНЫЕ РЕШЕНИЯ:
// - Компонент "тупой" — только отображает данные, все действия через коллбэки.
// - Активный тред подсвечивается через selectedThreadId.
// - Свайп для удаления — стандартный macOS/iOS паттерн (onDelete).
// - Двойной клик для переименования — будет добавлен в IT-06.

import SwiftUI
import ChappieCore

/// Список тредов для боковой панели.
///
/// ПОЧЕМУ ОТДЕЛЬНЫЙ КОМПОНЕНТ:
/// ThreadListView — самостоятельная единица UI с собственным состоянием
/// (редактирование названия). Вынесен из SidebarView для чистоты и тестируемости.
struct ThreadListView: View {

    // MARK: - Входные данные

    /// Список тредов для отображения (от ViewModel, уже отсортированы по updatedAt DESC)
    let threads: [ThreadMetadata]

    /// UUID активного треда — подсвечивается в списке
    let selectedThreadId: UUID?

    /// Коллбэк: пользователь выбрал тред
    let onSelect: (ThreadMetadata) -> Void

    /// Коллбэк: пользователь удалил тред (через свайп или контекстное меню)
    let onDelete: (ThreadMetadata) -> Void

    /// Коллбэк: пользователь переименовал тред
    let onRename: (ThreadMetadata, String) -> Void

    // MARK: - Локальное состояние

    /// UUID треда в режиме переименования (nil = нет активного редактирования)
    @State private var editingThreadId: UUID? = nil

    /// Временный текст при переименовании
    @State private var editingTitle: String = ""

    // MARK: - Body

    var body: some View {
        ForEach(threads) { thread in
            ThreadRowView(
                thread: thread,
                isSelected: thread.id == selectedThreadId,
                isEditing: editingThreadId == thread.id,
                editingTitle: $editingTitle,
                onTap: {
                    onSelect(thread)
                },
                onCommitRename: {
                    let trimmed = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        onRename(thread, trimmed)
                    }
                    editingThreadId = nil
                },
                onCancelRename: {
                    editingThreadId = nil
                },
                onStartRename: {
                    editingTitle = thread.title
                    editingThreadId = thread.id
                },
                onDelete: {
                    onDelete(thread)
                }
            )
        }
    }
}
