// MessageBubbleView.swift
// Chappie
//
// ПОЧЕМУ ЭТОТ ФАЙЛ СУЩЕСТВУЕТ:
// Ранее MessageBubble был приватной структурой внутри ContentView.swift.
// Вынесен в отдельный файл, чтобы:
//   1. ContentView не превращался в монолит
//   2. Компонент можно было переиспользовать (например, в поиске или предпросмотре)
//   3. Визуальная логика пузыря сообщения была изолирована и легко менялась
//
// ИЗМЕНЕНИЕ (Этап 6 — ТД-6):
// MessageBubbleView теперь принимает типизированный enum ChatMessage вместо struct.
//
// ИЗМЕНЕНИЕ (ТД-UX-PERF — Оптимизация производительности UI):
// Кейс .toolCall полностью убран из рендера этого компонента.
// .toolCall больше не попадают в ленту — они отображаются в StatusBarView.
// MessageBubbleView теперь рендерит ТОЛЬКО .message (текстовые сообщения).
//
// ИЗМЕНЕНИЕ (ТД-COST-SUMMARY — Self-Summary):
// В кейсе .message появилось 5-е поле `summary: String?`.
// Паттерн деструктуризации обновлён — добавлен `_` для summary,
// т.к. в UI этот блок не отображается (он нужен только для API-контекста).

import SwiftUI

/// Визуальное представление текстового сообщения в истории чата.
///
/// Рендерит только `.message` — пузырь с текстом от пользователя или от Чаппи.
/// `.toolCall` в этот компонент больше не попадают (они в StatusBarView).
struct MessageBubbleView: View {

    let msg: ChatMessage

    var body: some View {
        // Рендерим только .message. Если вдруг попадёт .toolCall — просто ничего не рисуем.
        // На практике этого не случится, так как ChatScrollView получает уже
        // отфильтрованный visibleMessages (только .message), но guard нужен
        // для корректного exhaustive switch в Swift 6.
        //
        // ВАЖНО: паттерн деструктурирует ВСЕ 5 полей кейса .message:
        //   id, isUser, text, cost, summary
        // summary игнорируется через `_` — в UI он не показывается,
        // он нужен только AIOrchestrator при сборке контекста для API.
        if case .message(_, let isUser, let text, let cost, _) = msg {
            messageBubble(isUser: isUser, text: text, cost: cost)
        }
    }

    // MARK: - Рендер обычного сообщения

    /// Пузырь текстового сообщения.
    ///
    /// Пользователь — справа, акцентный цвет (синий).
    /// Чаппи — слева, нейтральный фон окна.
    @ViewBuilder
    private func messageBubble(isUser: Bool, text: String, cost: Double?) -> some View {
        HStack {
            // Сообщения пользователя прижимаем вправо через левый Spacer
            if isUser { Spacer() }

            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .foregroundStyle(isUser
                                     ? AnyShapeStyle(.white)
                                     : AnyShapeStyle(.primary))
                    // Разрешаем выделение текста — пользователь должен иметь
                    // возможность скопировать код или ответ ИИ
                    .textSelection(.enabled)

                // Стоимость запроса — показываем только если она есть.
                // Помогает пользователю контролировать расход токенов в реальном времени.
                if let cost = cost {
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
                isUser
                ? Color.accentColor
                : Color(NSColor.windowBackgroundColor)
            )
            .cornerRadius(10)
            .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)

            // Сообщения Чаппи прижимаем влево через правый Spacer
            if !isUser { Spacer() }
        }
        // Используем id сообщения как anchor для ScrollViewReader.scrollTo()
        .id(msg.id)
    }
}

// MARK: - Preview

#Preview("Сообщения") {
    VStack(spacing: 12) {
        MessageBubbleView(msg: .message(isUser: true, text: "Привет, Чаппи!"))
        MessageBubbleView(msg: .message(isUser: false, text: "Привет, Босс! Готов к работе 🚀", cost: 1.23))
        MessageBubbleView(msg: .message(isUser: false, text: "Анализирую проект...", cost: nil))
    }
    .padding()
}
