<!--
  Chappie/AI_Docs/architecture.md

  ДОКУМЕНТ АРХИТЕКТУРЫ — CHAPPIE APP (UI LAYER)

  Этот файл описывает РЕАЛЬНУЮ архитектуру UI-слоя приложения Chappie.
  Обновлён после FIX-DOUBLE-CONTEXT (2026-06-02): устранено двойное сжатие истории.
  Обновляй при каждом значимом архитектурном изменении.
-->

# Chappie App — Архитектура UI-слоя

## 1. Философия и назначение

**Chappie.app** — SwiftUI-приложение для macOS 26+, которое является тонкой оболочкой над `ChappieCore`.
Его единственная ответственность — отображать данные пользователю и передавать действия в бизнес-логику.

### Принцип "тонкого UI"

- **Никакой бизнес-логики во View.** View только отображают данные из ViewModel.
- **Никакой прямой работы с сетью или файлами в UI.** Всё делегируется в ChappieCore.
- **ViewModel — единственный посредник** между UI и ChappieCore.
- **Каждый компонент — отдельный файл.**

---

## 2. Реальная структура файлов

```
Chappie/
├── ChappieApp.swift                    # @main, точка входа, создаёт WindowGroup → ContentView
├── ContentView.swift                   # Чистый "дирижёр": собирает компоненты, делегирует логику
├── ChappieViewModel.swift              # Единственный ViewModel (@Observable, @MainActor)
│                                       # + streamingText: String (ТД-7)
│                                       # + visibleMessages: [ChatMessage] (ТД-UX-PERF)
│                                       # + currentToolCall: String? (ТД-UX-PERF)
├── Models/
│   └── ChatMessage.swift               # enum ChatMessage: .message | .toolCall
├── Views/
│   ├── Chat/
│   │   ├── MessageBubbleView.swift     # Пузырёк одного сообщения (только .message)
│   │   ├── ChatScrollView.swift        # Лента сообщений + спиннер + стриминговый пузырь
│   │   └── StatusBarView.swift         # Строка состояния текущего инструмента (ТД-UX-PERF)
│   ├── Input/
│   │   └── InputBarView.swift          # Панель ввода: TextField + кнопка отправки
│   ├── Sidebar/
│   │   └── SidebarView.swift           # Боковая панель: воркспейс + предупреждения
│   └── Toolbar/
│       └── ToolbarContent.swift        # Тулбар: баланс + кнопка настроек
├── Settings/
│   ├── SettingsManager.swift           # Хранение и валидация API-ключа (Keychain)
│   └── SettingsView.swift              # Sheet настроек: ввод ключа, валидация, сохранение
├── Assets.xcassets/
└── AI_Docs/
    ├── semantic.json
    ├── architecture.md                 # Этот файл
    └── project_map.md
```

---

## 3. КРИТИЧЕСКИ ВАЖНО: Кто строит контекстное окно истории

### Проблема (была до FIX-DOUBLE-CONTEXT)

История сжималась **дважды** с **разными параметрами**:

1. `ChappieViewModel.buildNetworkHistory()` — tokenBudget=**30,000**, recentFullCount=**6**, summaryThreshold=**200**
2. `AIOrchestrator.buildContextWindow()` — tokenBudget=**12,000**, recentFullCount=**3**, summaryThreshold=**400**

Оркестратор получал уже сжатую историю и сжимал её снова. Параметры рассинхронизированы.
**Результат: 21,000+ токенов на запрос вместо ожидаемых 5,000-7,000.**

### Решение (FIX-DOUBLE-CONTEXT)

**Единственный источник истины для логики сжатия — `AIOrchestrator.buildContextWindow()`.**

| Компонент | Ответственность |
|---|---|
| `ChappieViewModel.buildRawNetworkHistory()` | ТОЛЬКО конвертация `ChatMessage` → `AIMessage`. Никакого сжатия! |
| `AIOrchestrator.buildContextWindow()` | Токенный бюджет, замена на summary, обрезка. Читает параметры из `AppConfig`. |
| `AppConfig.shared` | Единственное место где живут `tokenBudget`, `recentFullMessages`, `summaryThreshold`. |

### Как summary передаётся из ViewModel в Orchestrator

ViewModel встраивает summary обратно в текст сообщения как тег:
```swift
// buildRawNetworkHistory() в ViewModel
let textWithSummary = text + "\n<summary>\(summary)</summary>"
return AIMessage(role: "assistant", content: textWithSummary)
```

Оркестратор извлекает его через `extractSummary()` в `compressMessage()`:
```swift
// AIOrchestrator.compressMessage()
if let summary = extractSummary(from: fullText) {
    return AIMessage(role: ..., content: "[СЖАТО] \(summary)")
}
```

Это позволяет не менять сигнатуру `AIMessage` и сохранить чистый интерфейс.

---

## 4. Оптимизация производительности UI (ТД-UX-PERF)

### Проблема

Массив `messages` хранил все записи за всё время, включая тысячи `.toolCall`.
При ресайзе окна SwiftUI перерисовывал весь ForEach — отсюда тормоза и 200 МБ памяти.

### Решение: двойная оптимизация

#### 4.1 visibleMessages — фильтрация и лимит

```swift
var visibleMessages: [ChatMessage] {
    let onlyMessages = messages.filter { if case .message = $0 { return true }; return false }
    return Array(onlyMessages.suffix(30))   // макс. 30 .message в ленте
}
```

#### 4.2 currentToolCall — строка состояния

```swift
self.currentToolCall = "\(toolName) → \(shortPath)"  // во время работы
self.currentToolCall = nil                             // после завершения
```

---

## 5. Стриминг токенов (ТД-7)

```
AITunnelClient.streamRequest()     → AsyncThrowingStream<String, Error>
    ↓ каждый токен
AIOrchestrator.process(onToken:)   → вызывает onToken(@Sendable (String)->Void)
    ↓ Task { @MainActor in }
ChappieViewModel.streamingText     → @Observable, SwiftUI перерисовывает пузырь
    ↓
ChatScrollView.streamingBubble     → Text(streamingText) + BlinkingCursor
```

---

## 6. ChappieViewModel — публичный интерфейс

| Свойство / Метод | Тип | Назначение |
|---|---|---|
| `messages` | `[ChatMessage]` | Полная история. `didSet` → автосохранение на диск |
| `visibleMessages` | `[ChatMessage]` | Только `.message`, макс. 30 — для UI |
| `currentToolCall` | `String?` | Текущий инструмент для StatusBarView |
| `isThinking` | `Bool` | Флаг активного AI-запроса |
| `streamingText` | `String` | Накопленный текст стримингового ответа |
| `workspaceURL` | `URL?` | Текущий воркспейс |
| `currentBalance` | `Double?` | Баланс AITunnel |
| `send(prompt:)` | `func` | Отправить запрос в оркестратор (со стримингом) |
| `setWorkspace(_:)` | `func` | Подключить новую папку проекта |
| `updateApiKey(_:)` | `func` | Обновить ключ без перезапуска |
| `clearHistory()` | `func` | Очистить историю с приветствием |
| `buildRawNetworkHistory()` | `private func` | Конвертация в [AIMessage] БЕЗ сжатия |

---

## 7. Технический долг (актуальный)

| # | Описание | Приоритет | Статус |
|---|---|---|---|
| ТД-4 | ContentView-монолит → разбить на компоненты | 🟠 | ✅ Закрыт |
| ТД-6 | ToolCall-сообщения → типизировать | 🟡 | ✅ Закрыт |
| ТД-7 | Нет стриминга токенов | 🟡 | ✅ Закрыт |
| ТД-UX-PERF | Тормоза UI, 200 МБ памяти из-за .toolCall в ленте | 🔴 | ✅ Закрыт |
| ТД-SEC | API-ключ → Keychain | 🟠 | ✅ Закрыт |
| ТД-TEST | Unit-тесты | 🟡 | ✅ Закрыт |
| ТД-COST | Prompt caching + токенное окно | 🟡 | ✅ Закрыт |
| FIX-DOUBLE-CONTEXT | Двойное сжатие истории → единый источник истины | 🔴 | ✅ Закрыт |

---

## 📚 Changelog

| Date | Change |
|------|--------|
| 2026-05-21 | Initial creation |
| 2026-05-27 | Полная переработка: документ приведён в соответствие с реальным кодом |
| 2026-05-27 | Этап 4: ТД-4 закрыт. ContentView разбит на компоненты |
| 2026-05-27 | Этап 6: ChatMessage типизирован как enum. ТД-6 закрыт |
| 2026-05-28 | ТД-7: Стриминг токенов |
| 2026-06-01 | ТД-UX-PERF: visibleMessages, currentToolCall, StatusBarView |
| 2026-06-02 | FIX-DOUBLE-CONTEXT: buildRawNetworkHistory() — только конвертация без сжатия |
