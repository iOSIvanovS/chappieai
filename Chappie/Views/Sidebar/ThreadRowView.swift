// ThreadRowView.swift
// Chappie
//
// НАЗНАЧЕНИЕ:
// Одна строка треда в боковой панели. Отображает название, дату и кнопки действий.
//
// АРХИТЕКТУРНЫЕ РЕШЕНИЯ:
// - Inline-редактирование названия через TextField при двойном клике.
// - Контекстное меню (правый клик) с действиями: переименовать, удалить.
// - Кнопка удаления появляется при наведении (hover) — стандарт macOS.
// - Активная строка подсвечивается акцентным цветом.

import SwiftUI
import ChappieCore

/// Строка одного треда в боковой панели.
struct ThreadRowView: View {

    // MARK: - Входные данные

    let thread: ThreadMetadata
    let isSelected: Bool
    let isEditing: Bool
    @Binding var editingTitle: String

    let onTap: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onStartRename: () -> Void
    let onDelete: () -> Void

    // MARK: - Локальное состояние

    /// Флаг hover — показываем кнопку удаления только при наведении
    @State private var isHovered: Bool = false

    // MARK: - Форматтер даты

    /// Относительная дата: "Сегодня", "Вчера", "5 дней назад"
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.locale = Locale(identifier: "ru_RU")
        return f
    }()

    private var relativeDate: String {
        Self.relativeDateFormatter.localizedString(for: thread.updatedAt, relativeTo: Date())
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 6) {

            // MARK: Основной контент строки
            VStack(alignment: .leading, spacing: 2) {

                if isEditing {
                    // Режим редактирования — TextField вместо Text
                    TextField("Название треда", text: $editingTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .onSubmit { onCommitRename() }
                        // Escape отменяет переименование
                        .onKeyPress(.escape) {
                            onCancelRename()
                            return .handled
                        }
                        // Автофокус при входе в режим редактирования
                        .focused($isTextFieldFocused)
                        .onAppear { isTextFieldFocused = true }
                } else {
                    // Обычный режим — просто текст
                    Text(thread.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                // Дата последнего обновления
                Text(relativeDate)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary)
            }

            Spacer()

            // MARK: Кнопка удаления (показывается при hover или выборе)
            if (isHovered || isSelected) && !isEditing {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Удалить тред")
                // Небольшая анимация появления
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected
                      ? Color.accentColor
                      : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
        )
        // Одиночный клик — выбрать тред
        .onTapGesture { onTap() }
        // Двойной клик — начать переименование
        .onTapGesture(count: 2) { onStartRename() }
        // Отслеживаем hover для кнопки удаления
        .onHover { isHovered = $0 }
        // Контекстное меню (правый клик)
        .contextMenu {
            Button {
                onStartRename()
            } label: {
                Label("Переименовать", systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Удалить", systemImage: "trash")
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    // MARK: - FocusState для TextField

    /// FocusState для автофокуса при переименовании.
    ///
    /// ПОЧЕМУ @FocusState ВНУТРИ СТРОКИ:
    /// FocusState должен быть в том же View что и TextField.
    /// Если вынести в родителя — потребуется передавать Binding<Bool>,
    /// что усложняет интерфейс. Локальный @FocusState — чище.
    @FocusState private var isTextFieldFocused: Bool
}
