//
//  MessageBubbleView.swift
//  Chappie
//
//  ПОЧЕМУ ЭТОТ ФАЙЛ СУЩЕСТВУЕТ:
//  Ранее MessageBubble был приватной структурой внутри ContentView.swift.
//  Вынесен в отдельный файл, чтобы:
//  1. ContentView не превращался в монолит
//  2. Компонент можно было переиспользовать (например, в поиске или предпросмотре)
//  3. Визуальная логика пузыря сообщения была изолирована и легко менялась
//

import SwiftUI

/// Пузырь одного сообщения в чате.
///
/// Пузырь пользователя — справа, синий.
/// Пузырь Чаппи — слева, нейтральный фон.
/// Если у сообщения есть стоимость — показываем монетку снизу справа.
struct MessageBubbleView: View {
    
    let msg: ChatMessage
    
    var body: some View {
        HStack {
            // Сообщения пользователя выравниваем вправо — прижимаем левый Spacer
            if msg.isUser { Spacer() }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(msg.text)
                    .foregroundStyle(msg.isUser
                                     ? AnyShapeStyle(.white)
                                     : AnyShapeStyle(.primary))
                    // Разрешаем выделение текста — пользователь должен иметь
                    // возможность скопировать код или ответ ИИ
                    .textSelection(.enabled)
                
                // Стоимость запроса — показываем только если она есть.
                // Это помогает пользователю понимать расход токенов в реальном времени.
                if let cost = msg.cost {
                    Text(String(format: "🪙 %.2f ₽", cost))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding()
            .background(
                // Сообщения пользователя — акцентный цвет (синий по умолчанию)
                // Сообщения Чаппи — цвет фона окна (нейтральный, читаемый)
                msg.isUser
                ? Color.accentColor
                : Color(NSColor.windowBackgroundColor)
            )
            .cornerRadius(10)
            .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
            
            // Сообщения Чаппи выравниваем влево — прижимаем правый Spacer
            if !msg.isUser { Spacer() }
        }
        // Используем id сообщения как anchor для ScrollViewReader.scrollTo()
        .id(msg.id)
    }
}

#Preview {
    VStack(spacing: 12) {
        MessageBubbleView(msg: ChatMessage(isUser: true, text: "Привет, Чаппи!"))
        MessageBubbleView(msg: ChatMessage(isUser: false, text: "Привет, Босс! Готов к работе 🚀", cost: 1.23))
    }
    .padding()
}
