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
// Паттерн деструктуризации обновлён — добавлен `_` для summary.
//
// ИЗМЕНЕНИЕ (UX-ANIMATION — Плавное появление пузырей):
// Добавлен .transition на пузырь: новые сообщения плавно въезжают снизу
// с одновременным fade-in.
//
// ИЗМЕНЕНИЕ (UX-TYPOGRAPHY — Типографика и Markdown):
// Пузырь Чаппи теперь использует MarkdownTextView вместо Text():
//   - Блоки кода в стиле Xcode Intelligence Panel (тёмный фон, подсветка Swift)
//   - Инлайн-код, жирный, курсив, заголовки
//   - SF Pro Text 14pt, lineSpacing 5 (Apple HIG: 1.3–1.5× line-height)
//   - Кнопка копирования в блоках кода
//
// ДИЗАЙН ПУЗЫРЕЙ (Apple HIG + macOS 26):
// Пользователь: акцентный цвет (синий), белый текст — "наши" сообщения
// Чаппи: чистый фон с тонкой границей, как карточки в macOS 26 — нейтральный
// Оба пузыря: cornerRadius 12, тень 0.1 opacity — лёгкая, не агрессивная

import SwiftUI

/// Визуальное представление текстового сообщения в истории чата.
///
/// Рендерит только `.message` — пузырь с текстом от пользователя или от Чаппи.
/// Пузырь Чаппи использует MarkdownTextView для поддержки кода и форматирования.
/// Пузырь пользователя использует обычный Text — пользователь не пишет markdown.
struct MessageBubbleView: View {

    let msg: ChatMessage

    var body: some View {
        // Рендерим только .message. .toolCall в этот компонент не попадают.
        // ВАЖНО: паттерн деструктурирует ВСЕ 5 полей кейса .message:
        //   id, isUser, text, cost, summary
        // summary игнорируется через `_` — в UI он не показывается.
        if case .message(_, let isUser, let text, let cost, _) = msg {
            messageBubble(isUser: isUser, text: text, cost: cost)
                // АНИМАЦИЯ ПОЯВЛЕНИЯ:
                // .asymmetric: появление — въезд снизу + fade, исчезновение — только fade.
                // Это стандартный UX-паттерн мессенджеров (iMessage, Telegram).
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    )
                )
        }
    }

    // MARK: - Рендер пузыря

    /// Пузырь текстового сообщения.
    ///
    /// Пользователь — справа, акцентный цвет, белый текст, обычный Text.
    /// Чаппи — слева, нейтральный фон с границей, MarkdownTextView с поддержкой кода.
    @ViewBuilder
    private func messageBubble(isUser: Bool, text: String, cost: Double?) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Сообщения пользователя прижимаем вправо через левый Spacer
            if isUser { Spacer(minLength: 40) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {

                if isUser {
                    // ПУЗЫРЬ ПОЛЬЗОВАТЕЛЯ:
                    // Простой Text — пользователь не пишет markdown.
                    // Белый текст на акцентном фоне.
                    Text(text)
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .clipShape(
                            // Скруглённые углы: все 12pt, кроме нижнего правого — 4pt.
                            // Этот приём из iMessage создаёт "хвост" пузыря без лишней графики.
                            UnevenRoundedRectangle(
                                topLeadingRadius: 12,
                                bottomLeadingRadius: 12,
                                bottomTrailingRadius: 4,
                                topTrailingRadius: 12
                            )
                        )
                } else {
                    // ПУЗЫРЬ ЧАППИ:
                    // MarkdownTextView — поддержка кода, заголовков, форматирования.
                    // Нейтральный фон с тонкой границей — как карточки macOS 26.
                    MarkdownTextView(text: text, fontSize: 14)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            // Адаптивный фон: белый в Light mode, тёмно-серый в Dark mode.
                            // Используем systemBackground — стандарт Apple для "поверхности".
                            Color(NSColor.textBackgroundColor)
                        )
                        .clipShape(
                            // Зеркальный вариант: нижний левый угол — 4pt ("хвост" слева).
                            UnevenRoundedRectangle(
                                topLeadingRadius: 12,
                                bottomLeadingRadius: 4,
                                bottomTrailingRadius: 12,
                                topTrailingRadius: 12
                            )
                        )
                        .overlay(
                            // Тонкая граница — отделяет пузырь от фона окна.
                            // Особенно важна в Light mode где фон пузыря близок к фону окна.
                            UnevenRoundedRectangle(
                                topLeadingRadius: 12,
                                bottomLeadingRadius: 4,
                                bottomTrailingRadius: 12,
                                topTrailingRadius: 12
                            )
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                }

                // СТОИМОСТЬ ЗАПРОСА:
                // Показываем только для сообщений Чаппи с известной стоимостью.
                // Помогает контролировать расход токенов в реальном времени.
                if let cost = cost, !isUser {
                    Text(String(format: "🪙 %.2f ₽", cost))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 4)
                }
            }

            // Сообщения Чаппи прижимаем влево через правый Spacer
            if !isUser { Spacer(minLength: 40) }
        }
        // Используем id сообщения как anchor для ScrollViewReader.scrollTo()
        .id(msg.id)
    }
}

// MARK: - Preview

#Preview("Сообщения") {
    ScrollView {
        VStack(spacing: 16) {
            MessageBubbleView(msg: .message(isUser: true, text: "Привет, Чаппи! Как дела?"))

            MessageBubbleView(msg: .message(
                isUser: false,
                text: "Привет, Босс! 🚀 Всё отлично.\n\nВот пример кода:\n\n```swift\n// Стриминговый ответ\nfunc streamResponse() async {\n    for await token in stream {\n        await MainActor.run {\n            streamingText += token\n        }\n    }\n}\n```\n\nИспользуй **async/await** для работы с потоками.",
                cost: 1.23
            ))

            MessageBubbleView(msg: .message(
                isUser: true,
                text: "Понял, спасибо! А что насчёт `@Observable`?"
            ))

            MessageBubbleView(msg: .message(
                isUser: false,
                text: "## @Observable\n\n`@Observable` — это макрос Swift 5.9, который заменяет `ObservableObject`.\n\n**Преимущества:**\n- Нет `@Published` — все свойства автоматически отслеживаются\n- Работает с `@State` во View\n- Полная совместимость со Swift 6\n\n```swift\n@Observable\nfinal class ViewModel {\n    var count: Int = 0  // автоматически отслеживается\n}\n```",
                cost: 0.87
            ))
        }
        .padding()
    }
    .frame(width: 650, height: 700)
    .background(Color(NSColor.windowBackgroundColor))
}
