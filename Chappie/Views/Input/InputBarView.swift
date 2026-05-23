//
//  InputBarView.swift
//  Chappie
//
//  ПОЧЕМУ ЭТОТ ФАЙЛ СУЩЕСТВУЕТ:
//  Панель ввода — самостоятельный UI-компонент с собственной логикой:
//  - мультистрочный TextField с ограничением до 10 строк
//  - блокировка при отсутствии воркспейса или пока Чаппи думает
//  - отправка по Enter, перенос строки по ⌥+Enter
//  Вынесен из ContentView, чтобы его можно было изменять независимо.
//

import SwiftUI

/// Панель ввода сообщения внизу чата.
///
/// Содержит мультистрочный TextField и кнопку отправки.
/// Отключается если:
/// - воркспейс не выбран (некуда писать файлы)
/// - Чаппи сейчас думает (нельзя слать новый запрос пока не закончен предыдущий)
struct InputBarView: View {
    
    /// Текст, который вводит пользователь.
    /// Используем Binding, чтобы ContentView мог сбрасывать поле после отправки.
    @Binding var prompt: String
    
    /// Флаг: выбран ли воркспейс. Без воркспейса ввод заблокирован.
    let isWorkspaceSelected: Bool
    
    /// Флаг: Чаппи сейчас думает. Пока думает — ввод заблокирован.
    let isThinking: Bool
    
    /// Коллбэк, который вызывается при нажатии "Отправить".
    /// Логика отправки живёт во ViewModel, не здесь — компонент просто сигнализирует.
    let onSend: () -> Void
    
    /// Вычисляемый флаг: можно ли сейчас отправить сообщение.
    /// Все три условия должны выполняться одновременно.
    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && isWorkspaceSelected
        && !isThinking
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 12) {
                
                TextField(
                    "Напиши сообщение... (Enter — отправить, ⌥+Enter — перенос)",
                    text: $prompt,
                    axis: .vertical  // Разрешаем вертикальный рост поля
                )
                .textFieldStyle(.roundedBorder)
                // Ограничиваем рост: минимум 1 строка, максимум 10.
                // Это предотвращает "захват" всего экрана длинными промптами.
                .lineLimit(1...10)
                .onSubmit {
                    // onSubmit срабатывает при нажатии Enter.
                    // ⌥+Enter вставляет перенос строки — это стандартное поведение TextField.
                    onSend()
                }
                .disabled(!isWorkspaceSelected || isThinking)
                
                Button(action: onSend) {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
                // Небольшой отступ снизу чтобы кнопка была на одной линии
                // с нижним краем TextField при многострочном вводе
                .padding(.bottom, 2)
            }
        }
        .padding(12)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
        .padding(.horizontal)
        .padding(.bottom, 16)
    }
}

#Preview {
    VStack {
        Spacer()
        InputBarView(
            prompt: .constant(""),
            isWorkspaceSelected: true,
            isThinking: false,
            onSend: { print("Отправить!") }
        )
    }
    .frame(width: 600, height: 200)
}
