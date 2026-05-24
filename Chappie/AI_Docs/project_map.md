# Карта проекта: Chappie (App Target)

> **Обновлено:** 2026-06-01 — ТД-UX-PERF закрыт: visibleMessages, currentToolCall, StatusBarView.
> **Платформа:** macOS 26+, Swift 6, SwiftUI
> **Архитектура:** MVVM, @Observable, @MainActor

---

## 🗺️ Реальная структура файлов

```text
Chappie/
├── ChappieApp.swift                    # @main, точка входа, WindowGroup → ContentView
├── ContentView.swift                   # Чистый "дирижёр": прокидывает visibleMessages + currentToolCall
├── ChappieViewModel.swift              # Главная ViewModel (@Observable, @MainActor)
│                                       # + streamingText: String (ТД-7)
│                                       # + visibleMessages: [ChatMessage] (ТД-UX-PERF)
│                                       # + currentToolCall: String? (ТД-UX-PERF)
├── Models/
│   └── ChatMessage.swift               # enum ChatMessage: .message | .toolCall
├── Views/
│   ├── Chat/
│   │   ├── MessageBubbleView.swift     # Пузырёк сообщения (только .message, .toolCall убраны)
│   │   ├── ChatScrollView.swift        # Лента + спиннер + streamingBubble (макс. 30 элементов)
│   │   └── StatusBarView.swift         # Строка состояния текущего инструмента (ТД-UX-PERF)
│   ├── Input/
│   │   └── InputBarView.swift          # Панель ввода: TextField + кнопка отправки
│   ├── Sidebar/
│   │   └── SidebarView.swift           # Боковая панель: воркспейс + предупреждения
│   └── Toolbar/
│       └── ToolbarContent.swift        # Тулбар: баланс + кнопка настроек
├── Settings/
│   ├── SettingsManager.swift           # Хранение API-ключа в UserDefaults
│   └── SettingsView.swift              # Sheet настроек
├── Assets.xcassets/
└── AI_Docs/
    ├── semantic.json
    ├── architecture.md
    └── project_map.md                  # Этот файл
```

---

## 📝 Детальное описание файлов

### 1. `ChappieApp.swift`
- **Назначение:** Точка входа (`@main`). Минимальный bootstrap.

### 2. `ContentView.swift`
- **Назначение:** Чистый "дирижёр".
- **Изменение (ТД-UX-PERF):**
  - Передаёт `viewModel.visibleMessages` в `ChatScrollView` (было `viewModel.messages`)
  - Добавлен `StatusBarView(toolCall: viewModel.currentToolCall)` между чатом и InputBar
  - `withAnimation(.easeInOut(duration: 0.25))` — плавное появление/исчезновение строки

### 3. `Models/ChatMessage.swift`
- **Тип:** `public enum ChatMessage: Identifiable, Hashable, Codable`
- **Кейсы:** `.message(id:isUser:text:cost:)`, `.toolCall(id:toolName:targetPath:)`
- **Примечание:** `.toolCall` больше не рендерится в ленте — только хранится в `messages` для совместимости с историей на диске.

### 4. `ChappieViewModel.swift`
- **Тип:** `@Observable @MainActor final class`
- **Ключевые свойства:**
  - `messages: [ChatMessage]` — полная история (все записи, на диск)
  - `visibleMessages: [ChatMessage]` — только `.message`, макс. 30 **(ТД-UX-PERF)**
  - `currentToolCall: String?` — текущий инструмент для StatusBarView **(ТД-UX-PERF)**
  - `isThinking: Bool` — флаг активного запроса
  - `streamingText: String` — накопленный текст стримингового ответа **(ТД-7)**
  - `workspaceURL: URL?`, `currentBalance: Double?`
- **Изменение (ТД-UX-PERF):**
  - `onToolCall` коллбэк теперь обновляет `currentToolCall` вместо `messages.append(.toolCall)`
  - После завершения: `currentToolCall = nil`

### 5. `Views/Chat/MessageBubbleView.swift`
- **Изменение (ТД-UX-PERF):** Убран рендер `.toolCall`. Компонент рендерит только `.message`.

### 6. `Views/Chat/ChatScrollView.swift`
- **Входные данные:** `messages: [ChatMessage]` (теперь это `visibleMessages` — ≤30 элементов)
- **Изменение (ТД-UX-PERF):** ForEach работает с максимум 30 элементами — нет тормозов при ресайзе.

### 7. `Views/Chat/StatusBarView.swift` ← **НОВЫЙ ФАЙЛ (ТД-UX-PERF)**
- **Назначение:** Строка состояния текущего вызова инструмента.
- **Входные данные:** `toolCall: String?`
- **Поведение:** `nil` = скрыта, `String` = показывает иконку + текст
- **Дизайн:** маленький моноширинный шрифт, `.secondary` цвет, вращающаяся шестерёнка
- **Анимация:** `.transition(.move(edge: .bottom).combined(with: .opacity))`

### 8-12. Остальные файлы
- Без изменений.

---

## 🧩 Таблица Key Files

| File | Purpose | Тип |
|------|---------|-----|
| `ChappieApp.swift` | Точка входа | `@main struct` |
| `ContentView.swift` | Дирижёр | `struct View` |
| `Models/ChatMessage.swift` | Типизированная запись истории | `public enum` |
| `ChappieViewModel.swift` | ViewModel + стриминг + строка состояния | `@Observable @MainActor class` |
| `Views/Chat/MessageBubbleView.swift` | Рендер .message | `struct View` |
| `Views/Chat/ChatScrollView.swift` | Лента (≤30 элементов) + стриминговый пузырь | `struct View` |
| `Views/Chat/StatusBarView.swift` | Строка состояния инструмента | `struct View` |
| `Views/Input/InputBarView.swift` | Панель ввода | `struct View` |
| `Views/Sidebar/SidebarView.swift` | Боковая панель | `struct View` |
| `Views/Toolbar/ToolbarContent.swift` | Контент тулбара | `struct ToolbarContent` |
| `Settings/SettingsManager.swift` | API-ключ | `@Observable class`, singleton |
| `Settings/SettingsView.swift` | Sheet настроек | `struct View` |

---

## 🔄 Поток данных (ТД-UX-PERF)

```
messages (полная история, диск)
    ↓ visibleMessages (вычисляемое, только .message, suffix(30))
    ↓ ChatScrollView.messages → ForEach ≤30 элементов → MessageBubbleView

onToolCall { toolName, targetPath }
    ↓ currentToolCall = "toolName → shortPath"
    ↓ StatusBarView показывает строку
    ↓ (завершение) currentToolCall = nil → StatusBarView скрывается
```

---

## 🚧 Known Issues & TODOs

| # | Описание | Статус |
|---|---|---|
| ТД-4 | ContentView-монолит → компоненты | ✅ Закрыт |
| ТД-6 | ToolCall типизация | ✅ Закрыт |
| ТД-7 | Стриминг токенов | ✅ Закрыт |
| ТД-UX-PERF | Тормоза UI + 200 МБ памяти | ✅ Закрыт |
| ТД-COST | Оптимизация стоимости запросов | ✅ Закрыт (частично) |
| ТД-5 | API-ключ → Keychain | 🟡 Открыт |
| ТД-8 | Unit-тесты | 🟡 Открыт |

---

## 📚 Changelog

| Date | Change |
|------|--------|
| 2026-05-21 | Initial creation |
| 2026-05-27 | Полная переработка + компоненты (ТД-4) |
| 2026-05-27 | ChatMessage как enum (ТД-6) |
| 2026-05-28 | Стриминг токенов (ТД-7): streamingText, streamingBubble, BlinkingCursor |
| 2026-06-01 | ТД-UX-PERF: visibleMessages, currentToolCall, StatusBarView |
