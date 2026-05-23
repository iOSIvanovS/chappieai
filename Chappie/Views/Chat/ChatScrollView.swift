//
//  ChatScrollView.swift
//  Chappie
//
//  ПОЧЕМУ ЭТОТ ФАЙЛ СУЩЕСТВУЕТ:
//  Логика скролла чата (автоскролл при новых сообщениях, индикатор "думает")
//  была вшита прямо в body ContentView. Это делало ContentView сложным для
//  понимания и изменения. Здесь собрана вся логика отображения ленты сообщений.
//

import SwiftUI

/// Прокручиваемая лента сообщений чата с автоскроллом и индикатором размышления.
///
/// Компонент самодостаточен: он сам следит за изменениями в массиве сообщений
/// и автоматически прокручивается вниз при появлении нового сообщения или
/// при включении индикатора "Чаппи думает".
struct ChatScrollView: View {
    
    /// Список сообщений для отображения
    let messages: [ChatMessage]
    
    /// Флаг: Чаппи сейчас думает (показываем спиннер)
    let isThinking: Bool
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    
                    // Приветственный экран — показываем только если чат пуст.
                    // Это первое, что видит пользователь, и оно должно быть дружелюбным.
                    if messages.isEmpty {
                        welcomeMessage
                    } else {
                        // Рендерим каждый пузырь сообщения
                        ForEach(messages) { msg in
                            MessageBubbleView(msg: msg)
                        }
                    }
                    
                    // Индикатор "Чаппи думает" — появляется пока оркестратор работает.
                    // Показываем его ПОСЛЕ всех сообщений, чтобы он был последним в ленте.
                    if isThinking {
                        thinkingIndicator
                            .id("ThinkingIndicator")
                    }
                    
                    // Невидимый якорь в самом низу ленты.
                    // ScrollViewReader.scrollTo("BottomSpacer") всегда приведёт
                    // пользователя к последнему сообщению, независимо от их количества.
                    Spacer(minLength: 0)
                        .id("BottomSpacer")
                }
                .padding()
            }
            // При первом появлении — скроллим вниз, чтобы показать последнее сообщение
            .onAppear {
                proxy.scrollTo("BottomSpacer", anchor: .bottom)
            }
            // При добавлении нового сообщения — плавно скроллим вниз
            .onChange(of: messages) { _, _ in
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo("BottomSpacer", anchor: .bottom)
                }
            }
            // Когда Чаппи начинает думать — скроллим к спиннеру,
            // чтобы пользователь видел что что-то происходит
            .onChange(of: isThinking) { _, isThinking in
                if isThinking {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo("BottomSpacer", anchor: .bottom)
                    }
                }
            }
        }
    }
    
    // MARK: - Вспомогательные подвью
    
    /// Приветственное сообщение для пустого чата.
    /// Выровнено влево — как обычный ответ Чаппи, чтобы не ломать визуальный ритм.
    private var welcomeMessage: some View {
        HStack {
            Text("Привет! Я — Чаппи. Выбери проект и скажи, что нужно сделать.")
                .padding()
                .background(Color(NSColor.windowBackgroundColor))
                .cornerRadius(10)
                .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
            Spacer()
        }
    }
    
    /// Индикатор загрузки пока Чаппи обрабатывает запрос.
    /// Спиннер выровнен влево — он "говорит" от имени Чаппи.
    private var thinkingIndicator: some View {
        HStack {
            ProgressView()
                .padding()
                .background(Color(NSColor.windowBackgroundColor))
                .cornerRadius(10)
                .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
            Spacer()
        }
    }
}

#Preview {
    ChatScrollView(
        messages: [
            ChatMessage(isUser: true, text: "Привет!"),
            ChatMessage(isUser: false, text: "Привет, Босс! 🚀", cost: 0.42)
        ],
        isThinking: true
    )
    .frame(width: 600, height: 400)
}
