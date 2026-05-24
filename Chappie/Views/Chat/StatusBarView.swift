//
//  StatusBarView.swift
//  Chappie
//
//  ПОЧЕМУ ЭТОТ ФАЙЛ СУЩЕСТВУЕТ:
//  Раньше каждый вызов инструмента (read_file, write_file, memorize и т.д.)
//  добавлял запись .toolCall в ленту чата. За один сложный запрос Чаппи может
//  вызвать 20-50 инструментов — это засоряло ленту и создавало огромный список
//  для рендера, что вызывало тормоза при ресайзе окна и поедало 200 МБ памяти.
//
//  РЕШЕНИЕ:
//  Вместо записей в ленте — одна строка состояния между чатом и полем ввода.
//  Она показывает ТЕКУЩИЙ вызов инструмента (один элемент, а не тысячи).
//  Когда Чаппи заканчивает работу — строка плавно скрывается.
//
//  ДИЗАЙН:
//  Строка намеренно скромная: маленький шрифт, приглушённый цвет, иконка + текст.
//  Она не должна отвлекать от диалога — это "подсказка о процессе", а не контент.

import SwiftUI

/// Строка состояния — показывает текущий вызов инструмента Чаппи.
///
/// Отображается только когда `toolCall != nil`, то есть пока Чаппи
/// активно вызывает инструменты. Плавно появляется и исчезает через анимацию.
struct StatusBarView: View {

    /// Текущая строка состояния вида "read_file → ContentView.swift"
    /// nil = строка скрыта (Чаппи не работает или уже завершил)
    let toolCall: String?

    var body: some View {
        // Используем if let с анимацией через .transition — строка плавно
        // появляется снизу и исчезает, не вызывая резкого сдвига layout-а.
        if let toolCall = toolCall {
            HStack(spacing: 6) {
                // Иконка "шестерёнка в движении" — универсальный символ "работает"
                Image(systemName: "gearshape.arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    // Вращение иконки — визуально подчёркивает что процесс идёт
                    .symbolEffect(.rotate, options: .repeating)

                // Текст вида "read_file → ContentView.swift"
                Text(toolCall)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    // Если строка длинная — обрезаем в середине: сохраняем начало и конец
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(
                // Тонкая полупрозрачная полоска — не перекрывает фон,
                // но визуально отделяет строку от чата и поля ввода
                Color(NSColor.windowBackgroundColor).opacity(0.85)
            )
            .overlay(alignment: .top) {
                // Тонкая разделительная линия сверху — отделяет от чата
                Divider()
            }
            // Плавное появление снизу — менее агрессивно чем .opacity,
            // не вызывает layout-скачков у соседних компонентов
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Preview

#Preview("Активный вызов") {
    VStack {
        Spacer()
        StatusBarView(toolCall: "write_file → Chappie/Views/Chat/StatusBarView.swift")
    }
    .frame(width: 600, height: 100)
}

#Preview("Длинный путь (обрезка)") {
    VStack {
        Spacer()
        StatusBarView(toolCall: "read_file → ChappieCore/Sources/ChappieCore/Services/AIOrchestrator.swift")
    }
    .frame(width: 400, height: 100)
}

#Preview("Скрытая (нет активности)") {
    VStack {
        Spacer()
        StatusBarView(toolCall: nil)
    }
    .frame(width: 600, height: 100)
}
