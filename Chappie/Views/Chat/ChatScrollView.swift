//
//  ChatScrollView.swift
//  Chappie
//
//  ПОЧЕМУ ЭТОТ ФАЙЛ СУЩЕСТВУЕТ:
//  Логика скролла чата (автоскролл при новых сообщениях, индикатор "думает")
//  была вшита прямо в body ContentView. Это делало ContentView сложным для
//  понимания и изменения. Здесь собрана вся логика отображения ленты сообщений.
//
//  ИЗМЕНЕНИЕ (Этап 6 — ТД-6):
//  #Preview обновлён под новый enum ChatMessage.
//
//  ИЗМЕНЕНИЕ (ТД-7 — Стриминг):
//  Добавлен параметр `streamingText: String`.
//  Когда streamingText не пуст — показываем "живой" стриминговый пузырь
//  вместо спиннера ProgressView.
//
//  ИЗМЕНЕНИЕ (ТД-UX-PERF — Оптимизация производительности UI):
//  ChatScrollView теперь принимает `visibleMessages` — уже отфильтрованный
//  и обрезанный до 30 элементов список.
//
//  ИЗМЕНЕНИЕ (UX-ANIMATION — Плавные анимации):
//  Spring-анимации для появления пузырей, easeInOut для спиннера.
//
//  ИЗМЕНЕНИЕ (UX-SMOOTH-ANIMATION — Плавное нарастание текста):
//  .contentTransition(.interpolate) на стриминговом пузыре.
//
//  ИЗМЕНЕНИЕ (UX-TYPOGRAPHY — Типографика):
//  Стриминговый пузырь теперь использует MarkdownTextView вместо Text() —
//  код подсвечивается в реальном времени по мере нарастания токенов.
//
//  ИЗМЕНЕНИЕ (UX-RUNNING-COST — Накопительная стоимость):
//  Добавлен параметр `runningCost: Double`.
//  Отображается в правом нижнем углу стримингового пузыря нарастающим итогом.
//  Анимируется через .contentTransition(.numericText) — числа "перекатываются".

import SwiftUI

/// Прокручиваемая лента сообщений чата с автоскроллом и индикатором размышления.
///
/// Компонент самодостаточен: он сам следит за изменениями в массиве сообщений
/// и автоматически прокручивается вниз при появлении нового сообщения или
/// при включении индикатора "Чаппи думает".
///
/// ВАЖНО: Принимает `visibleMessages` — уже отфильтрованный список (только .message,
/// максимум 30 штук). Фильтрация происходит в ViewModel, а не здесь.
struct ChatScrollView: View {

    /// Отфильтрованный список сообщений для отображения (только .message, макс. 30)
    let messages: [ChatMessage]

    /// Флаг: Чаппи сейчас думает (показываем спиннер или стриминговый пузырь)
    let isThinking: Bool

    /// Накопленный текст стримингового ответа.
    ///
    /// Пока пуст — показываем спиннер (Чаппи вызывает инструменты).
    /// Когда появляются первые символы — заменяем спиннер на "живой" пузырь.
    /// После завершения стриминга ViewModel сбросит это в "" и добавит .message в историю.
    let streamingText: String

    /// Накопительная стоимость текущего запроса — нарастающий итог.
    ///
    /// Обновляется после каждого внутреннего API-вызова оркестратора.
    /// Отображается в правом нижнем углу стримингового пузыря.
    /// 0.0 — в начале запроса (до первого ответа API).
    let runningCost: Double

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {

                    // Приветственный экран — показываем только если чат пуст.
                    if messages.isEmpty && !isThinking {
                        welcomeMessage
                            .transition(.opacity)
                    } else {
                        // ForEach теперь работает с максимум 30 элементами.
                        ForEach(messages) { msg in
                            MessageBubbleView(msg: msg)
                        }
                    }

                    // СТРИМИНГОВЫЙ БЛОК:
                    // 1. isThinking == false → ничего
                    // 2. isThinking == true, streamingText == "" → спиннер
                    // 3. isThinking == true, streamingText != "" → живой пузырь
                    if isThinking {
                        if streamingText.isEmpty {
                            thinkingIndicator
                                .transition(.opacity)
                                .id("thinking-spinner")
                        } else {
                            streamingBubble
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity
                                ))
                                .id("thinking-streaming")
                        }
                    }

                    // Невидимый якорь в самом низу ленты
                    Spacer(minLength: 0)
                        .id("BottomSpacer")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: messages)
                .animation(.easeInOut(duration: 0.25), value: isThinking)
                .animation(.easeInOut(duration: 0.3), value: streamingText.isEmpty)
            }
            .onAppear {
                proxy.scrollTo("BottomSpacer", anchor: .bottom)
            }
            .onChange(of: messages) { _, _ in
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo("BottomSpacer", anchor: .bottom)
                }
            }
            .onChange(of: isThinking) { _, isThinking in
                if isThinking {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo("BottomSpacer", anchor: .bottom)
                    }
                }
            }
            .onChange(of: streamingText) { _, _ in
                proxy.scrollTo("BottomSpacer", anchor: .bottom)
            }
        }
    }

    // MARK: - Вспомогательные подвью

    /// Приветственное сообщение для пустого чата.
    ///
    /// Дизайн: нейтральный пузырь слева — как первое сообщение от Чаппи.
    /// Использует ту же стилизацию что и пузырь Чаппи в MessageBubbleView.
    private var welcomeMessage: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Привет! Я — Чаппи 👋")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Выбери папку проекта в сайдбаре и скажи, что нужно сделать.")
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 12,
                    bottomLeadingRadius: 4,
                    bottomTrailingRadius: 12,
                    topTrailingRadius: 12
                )
            )
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 12,
                    bottomLeadingRadius: 4,
                    bottomTrailingRadius: 12,
                    topTrailingRadius: 12
                )
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )

            Spacer(minLength: 40)
        }
    }

    /// Спиннер — показывается пока Чаппи думает или вызывает инструменты.
    ///
    /// Минималистичный: только ProgressView в пузыре слева.
    /// Текущий инструмент отображается в StatusBarView ниже.
    private var thinkingIndicator: some View {
        HStack {
            ProgressView()
                .controlSize(.small)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 12,
                        bottomLeadingRadius: 4,
                        bottomTrailingRadius: 12,
                        topTrailingRadius: 12
                    )
                )
                .overlay(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 12,
                        bottomLeadingRadius: 4,
                        bottomTrailingRadius: 12,
                        topTrailingRadius: 12
                    )
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )

            Spacer(minLength: 40)
        }
    }

    /// "Живой" пузырь с нарастающим текстом стримингового ответа.
    ///
    /// ПОЧЕМУ MarkdownTextView, А НЕ Text:
    /// Чаппи может начать писать блок кода уже в середине стриминга.
    /// MarkdownTextView обрабатывает незавершённые блоки корректно —
    /// незакрытый ``` просто рендерится как текст до закрытия.
    ///
    /// ПОЧЕМУ .contentTransition(.interpolate):
    /// При каждом токене SwiftUI перерисовывает View с новой строкой.
    /// .interpolate плавно анимирует изменение между кадрами — эффект "печатания".
    ///
    /// СТОИМОСТЬ В ПРАВОМ НИЖНЕМ УГЛУ:
    /// runningCost показывается всегда (даже 0.00 ₽ в начале) — это честно.
    /// .contentTransition(.numericText) анимирует изменение числа — цифры "перекатываются".
    /// Это создаёт эффект "счётчика такси" — пользователь видит как растёт цена.
    private var streamingBubble: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom, spacing: 0) {
                    // MarkdownTextView для реалтайм-подсветки кода во время стриминга
                    MarkdownTextView(text: streamingText, fontSize: 14)
                        .contentTransition(.interpolate)
                        .animation(.linear(duration: 0.08), value: streamingText)

                    // Мигающий курсор — визуальный индикатор что текст ещё пишется
                    BlinkingCursor()
                        .padding(.bottom, 1)
                }

                // НАКОПИТЕЛЬНАЯ СТОИМОСТЬ:
                // Прижата к правому краю через HStack со Spacer.
                // .contentTransition(.numericText) — числа анимируются при изменении.
                // Показываем всегда: 0.00 ₽ → 1.23 ₽ → 4.56 ₽ — нарастающий итог.
                HStack {
                    Spacer()
                    Text(String(format: "🪙 %.2f ₽", runningCost))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .contentTransition(.numericText(value: runningCost))
                        .animation(.easeInOut(duration: 0.3), value: runningCost)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 12,
                    bottomLeadingRadius: 4,
                    bottomTrailingRadius: 12,
                    topTrailingRadius: 12
                )
            )
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 12,
                    bottomLeadingRadius: 4,
                    bottomTrailingRadius: 12,
                    topTrailingRadius: 12
                )
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )

            Spacer(minLength: 40)
        }
    }
}

// MARK: - BlinkingCursor

/// Мигающий курсор для стримингового пузыря.
///
/// Вынесен в отдельную View, чтобы анимация была изолирована и не влияла
/// на перерисовку родительского пузыря при каждом новом токене.
private struct BlinkingCursor: View {
    @State private var isVisible = true

    var body: some View {
        Text("▍")
            .font(.system(size: 14))
            .foregroundStyle(Color.accentColor)
            .opacity(isVisible ? 1 : 0)
            .animation(
                .easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                value: isVisible
            )
            .onAppear {
                isVisible = false
            }
    }
}

// MARK: - Preview

#Preview("С историей и стримингом") {
    ChatScrollView(
        messages: [
            .message(isUser: true, text: "Покажи пример кода"),
            .message(
                isUser: false,
                text: "Конечно! Вот пример:\n\n```swift\n// Пример ViewModel\n@Observable\nfinal class ViewModel {\n    var count = 0\n}\n```\n\nИспользуй **@Observable** для автоматического отслеживания.",
                cost: 0.42
            ),
        ],
        isThinking: true,
        streamingText: "Также можно добавить `@MainActor` для **потокобезопасности**...",
        runningCost: 1.23
    )
    .frame(width: 650, height: 500)
    .background(Color(NSColor.windowBackgroundColor))
}

#Preview("Спиннер (инструменты)") {
    ChatScrollView(
        messages: [
            .message(isUser: true, text: "Проанализируй проект"),
        ],
        isThinking: true,
        streamingText: "",
        runningCost: 0.0
    )
    .frame(width: 650, height: 300)
    .background(Color(NSColor.windowBackgroundColor))
}

#Preview("Пустой чат") {
    ChatScrollView(
        messages: [],
        isThinking: false,
        streamingText: "",
        runningCost: 0.0
    )
    .frame(width: 650, height: 300)
    .background(Color(NSColor.windowBackgroundColor))
}
