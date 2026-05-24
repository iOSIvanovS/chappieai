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
//  и обрезанный до 30 элементов список. Это снимает нагрузку с рендера:
//  ForEach больше не итерирует тысячи записей при каждом ресайзе окна.
//  .toolCall полностью убраны из ленты — они отображаются в StatusBarView.
//
//  ИЗМЕНЕНИЕ (UX-ANIMATION — Плавные анимации):
//  1. ForEach обёрнут в VStack с .animation(.spring(response:0.4), value: messages) —
//     новые пузыри плавно "въезжают", а не появляются рывком.
//  2. Переход спиннер ↔ стриминговый пузырь анимирован через withAnimation +
//     .transition(.opacity) — исчезновение/появление без резкого скачка.
//  3. Переход isThinking off → on анимирован аналогично.
//
//  ПОЧЕМУ .spring, А НЕ .easeInOut:
//  Spring-анимация с response=0.4 даёт лёгкий "отскок" — это ощущение живости,
//  характерное для нативных приложений Apple. easeInOut выглядит более "механически".

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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // .animation на VStack — это ключевой приём:
                // SwiftUI видит изменение массива messages и плавно анимирует
                // появление/исчезновение дочерних вью через их .transition.
                // Без этого модификатора .transition в MessageBubbleView не работает.
                VStack(spacing: 12) {

                    // Приветственный экран — показываем только если чат пуст.
                    if messages.isEmpty && !isThinking {
                        welcomeMessage
                            // Приветствие тоже плавно исчезает когда появляется первое сообщение
                            .transition(.opacity)
                    } else {
                        // ForEach теперь работает с максимум 30 элементами —
                        // ресайз окна больше не вызывает лагов.
                        // Каждый MessageBubbleView имеет свой .transition (move + opacity).
                        ForEach(messages) { msg in
                            MessageBubbleView(msg: msg)
                        }
                    }

                    // СТРИМИНГОВЫЙ БЛОК: показываем пока Чаппи думает/генерирует.
                    // Три состояния:
                    //   1. isThinking == false → ничего не показываем
                    //   2. isThinking == true, streamingText == "" → спиннер (инструменты)
                    //   3. isThinking == true, streamingText != "" → живой пузырь (генерация)
                    if isThinking {
                        if streamingText.isEmpty {
                            // Чаппи ещё не начал генерировать финальный ответ —
                            // он либо думает, либо вызывает инструменты.
                            // Текущий инструмент отображается в StatusBarView ниже.
                            thinkingIndicator
                                // Спиннер плавно появляется и исчезает через opacity.
                                // .id("thinking") нужен чтобы SwiftUI понимал что это
                                // разные вью при переходе спиннер ↔ пузырь — иначе
                                // анимация не сработает (SwiftUI посчитает их одним элементом).
                                .transition(.opacity)
                                .id("thinking-spinner")
                        } else {
                            // Финальный ответ генерируется прямо сейчас.
                            // Показываем накопленный текст как "живой" пузырь.
                            // Курсор-мигалка даёт понять что текст ещё пишется.
                            streamingBubble
                                // Пузырь появляется снизу — та же анимация что и обычные сообщения,
                                // чтобы переход от спиннера к тексту был визуально единым.
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity
                                ))
                                .id("thinking-streaming")
                        }
                    }

                    // Невидимый якорь в самом низу ленты.
                    Spacer(minLength: 0)
                        .id("BottomSpacer")
                }
                .padding()
                // КЛЮЧЕВОЙ МОДИФИКАТОР АНИМАЦИИ:
                // Привязываем анимацию к изменению массива messages.
                // Когда messages меняется — SwiftUI плавно анимирует появление/исчезновение
                // дочерних вью, используя их .transition. Spring даёт живой "отскок".
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: messages)
                // Отдельная анимация для isThinking — чтобы спиннер и стриминговый пузырь
                // тоже появлялись плавно, а не мгновенно.
                .animation(.easeInOut(duration: 0.25), value: isThinking)
                // Анимация для переключения спиннер ↔ пузырь внутри isThinking == true.
                // Без этого переход между двумя состояниями был бы резким.
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
            // Автоскролл при каждом новом токене стриминга.
            // Без этого пузырь растёт вниз за пределы видимой области.
            .onChange(of: streamingText) { _, _ in
                // Без анимации — токены приходят очень часто (десятки в секунду),
                // анимация каждого скролла создала бы визуальный "дрожащий" эффект.
                proxy.scrollTo("BottomSpacer", anchor: .bottom)
            }
        }
    }

    // MARK: - Вспомогательные подвью

    /// Приветственное сообщение для пустого чата.
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

    /// Спиннер — показывается пока Чаппи думает или вызывает инструменты.
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

    /// "Живой" пузырь с нарастающим текстом стримингового ответа.
    ///
    /// ПОЧЕМУ МИГАЮЩИЙ КУРСОР:
    /// Без визуального индикатора пользователь не понимает — текст уже закончился
    /// или ещё пишется. Мигающий курсор — универсальный UX-паттерн для "печатает".
    private var streamingBubble: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                // Текст с мигающим курсором в конце.
                // Курсор реализован как отдельный Text с анимацией opacity —
                // это дешевле чем таймер или кастомный ViewModifier.
                HStack(alignment: .bottom, spacing: 0) {
                    Text(streamingText)
                        .foregroundStyle(Color.primary)
                        .textSelection(.enabled)

                    // Мигающий курсор — анимируется через repeatForever
                    BlinkingCursor()
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            .cornerRadius(10)
            .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)

            Spacer()
        }
    }
}

// MARK: - BlinkingCursor

/// Мигающий курсор для стримингового пузыря.
///
/// Вынесен в отдельную View, чтобы анимация была изолирована и не влияла
/// на перерисовку родительского пузыря при каждом новом токене.
private struct BlinkingCursor: View {
    /// Состояние видимости курсора — переключается анимацией
    @State private var isVisible = true

    var body: some View {
        Text("▍")
            .foregroundStyle(Color.accentColor)
            .opacity(isVisible ? 1 : 0)
            // repeatForever с autoreverse создаёт плавное мигание без резких скачков
            .animation(
                .easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                value: isVisible
            )
            .onAppear {
                // Запускаем анимацию сразу при появлении курсора
                isVisible = false
            }
    }
}

// MARK: - Preview

#Preview("С историей и стримингом") {
    ChatScrollView(
        messages: [
            .message(isUser: true, text: "Привет, Чаппи!"),
            .message(isUser: false, text: "Привет, Босс! Готов к работе 🚀", cost: 0.42),
        ],
        isThinking: true,
        streamingText: "Прочитал файл. Вот что я нашёл: ContentView является чистым дирижёром..."
    )
    .frame(width: 600, height: 400)
}

#Preview("Спиннер (инструменты)") {
    ChatScrollView(
        messages: [
            .message(isUser: true, text: "Проанализируй проект"),
        ],
        isThinking: true,
        streamingText: ""
    )
    .frame(width: 600, height: 300)
}

#Preview("Пустой чат") {
    ChatScrollView(
        messages: [],
        isThinking: false,
        streamingText: ""
    )
    .frame(width: 600, height: 300)
}
