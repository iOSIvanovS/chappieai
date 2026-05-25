<!--
  Chappie/architecture.md

  ЕДИНЫЙ ДОКУМЕНТ АРХИТЕКТУРЫ — CHAPPIE APP (UI LAYER)

  Последнее обновление: UX-TYPOGRAPHY — Markdown + подсветка синтаксиса
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
├── ChappieApp.swift                    # @main, точка входа, AppDelegate для terminateHelper
├── MCPHelperLauncher.swift             # Управляет жизненным циклом дочернего процесса ChappieMCP
├── ContentView.swift                   # Чистый "дирижёр": собирает компоненты, делегирует логику
├── ChappieViewModel.swift              # Единственный ViewModel (@Observable, @MainActor)
│                                       # + streamingText: String (ТД-7)
│                                       # + visibleMessages: [ChatMessage] (ТД-UX-PERF)
│                                       # + currentToolCall: String? (ТД-UX-PERF)
├── Models/
│   └── ChatMessage.swift               # enum ChatMessage: .message | .toolCall
├── ChappieMCP/                         # Xcode-таргет: исходники хелпера
│   ├── main.swift
│   ├── MCPHTTPServer.swift
│   ├── GitTools.swift
│   └── BuildTools.swift
├── Views/
│   ├── Chat/
│   │   ├── MessageBubbleView.swift     # Пузырёк одного сообщения (только .message)
│   │   ├── ChatScrollView.swift        # Лента сообщений + спиннер + стриминговый пузырь
│   │   ├── MarkdownTextView.swift      # Рендер Markdown + подсветка синтаксиса (UX-TYPOGRAPHY)
│   │   └── StatusBarView.swift         # Строка состояния текущего инструмента
│   ├── Input/
│   │   └── InputBarView.swift          # Панель ввода: TextField + кнопка отправки
│   ├── Sidebar/
│   │   └── SidebarView.swift           # Боковая панель: воркспейс + предупреждения
│   └── Toolbar/
│       └── ToolbarContent.swift        # Тулбар: баланс + кнопка настроек
├── Settings/
│   ├── KeychainManager.swift
│   ├── SettingsManager.swift
│   └── SettingsView.swift
└── Assets.xcassets/
```

---

## 3. MCP Helper Architecture

### Как работает дочерний процесс ChappieMCP

```
ChappieViewModel.loadWorkspaceWithSecurityScope()  ← при старте (восстановление)
    или
ChappieViewModel.setWorkspace()                    ← при ручном выборе папки
    ↓
MCPHelperLauncher.shared.launch(workspacePath:)
    ↓
Bundle.main → Contents/Helpers/ChappieMCP (бинарник)
    ↓
Process.run(arguments: [workspacePath, socketPath])
    ↓
ChappieMCP слушает /tmp/com.chappie.mcp.sock
    ↓
MCPToolBridge в ChappieCore → connect() → ToolDispatcher → GitTools/BuildTools
```

### КРИТИЧЕСКИ ВАЖНО: Когда запускать хелпер

**РЕШЕНИЕ:** Хелпер запускается ТОЛЬКО когда путь к воркспейсу известен:
- `loadWorkspaceWithSecurityScope()` — после успешного восстановления bookmark
- `setWorkspace()` — при ручном выборе папки
- `ChappieApp.onAppear` — НЕ запускает хелпер (убрано)

### App Sandbox

**РЕШЕНИЕ:** `ENABLE_APP_SANDBOX = NO` в Debug и Release. Сокет в `/tmp/com.chappie.mcp.sock`.

---

## 4. КРИТИЧЕСКИ ВАЖНО: Кто строит контекстное окно истории

### Решение (FIX-DOUBLE-CONTEXT)

| Компонент | Ответственность |
|---|---|
| `ChappieViewModel.buildRawNetworkHistory()` | ТОЛЬКО конвертация `ChatMessage` → `AIMessage`. Никакого сжатия! |
| `AIOrchestrator.buildContextWindow()` | Токенный бюджет, замена на summary, обрезка |
| `AppConfig.shared` | Единственное место где живут параметры сжатия |

---

## 5. Оптимизация производительности UI (ТД-UX-PERF)

```swift
var visibleMessages: [ChatMessage] {
    let onlyMessages = messages.filter { if case .message = $0 { return true }; return false }
    return Array(onlyMessages.suffix(30))   // макс. 30 .message в ленте
}
```

---

## 6. Стриминг токенов (ТД-7)

```
AITunnelClient.streamRequest()     → AsyncThrowingStream<String, Error>
    ↓ каждый токен
AIOrchestrator.process(onToken:)   → вызывает onToken(@Sendable (String)->Void)
    ↓ Task { @MainActor in }
ChappieViewModel.streamingText     → @Observable, SwiftUI перерисовывает пузырь
    ↓
ChatScrollView.streamingBubble     → MarkdownTextView(streamingText) + BlinkingCursor
```

---

## 7. UX-TYPOGRAPHY — Markdown и подсветка синтаксиса

### Компоненты

**`MarkdownTextView`** — главный компонент рендера markdown-текста.
- Используется в пузырях Чаппи (не пользователя — тот не пишет markdown)
- Используется в стриминговом пузыре (код подсвечивается в реальном времени)

**`InlineTextView`** — рендер инлайн-разметки через AttributedString.
- Обрабатывает: `**bold**`, `*italic*`, `` `code` ``
- ПОЧЕМУ AttributedString: в macOS 26 оператор `+` для Text deprecated.
  Единственный надёжный способ смешивать стили — AttributedString с явными атрибутами.

**`CodeBlockView`** — блок кода в стиле Xcode Intelligence Panel.
- Тёмный фон #1E1E1E (Xcode Default Dark)
- Заголовок: язык слева, кнопка "Копировать" справа
- Горизонтальный скролл для длинных строк
- SF Mono 12.5pt, lineSpacing 4

**`SyntaxHighlightedText`** — подсветка синтаксиса Swift через AttributedString.
- Цветовая схема Xcode Default Dark (розовый для ключевых слов, голубой для типов и т.д.)
- Без сторонних зависимостей — собственный линейный парсер

### Дизайн пузырей (Apple HIG + macOS 26)

**Пузырь пользователя:**
- Акцентный цвет (синий), белый текст
- `UnevenRoundedRectangle`: все углы 12pt, нижний правый 4pt ("хвост" справа)
- Обычный `Text` — пользователь не пишет markdown

**Пузырь Чаппи:**
- `Color(NSColor.textBackgroundColor)` — адаптивный (белый/тёмный)
- `UnevenRoundedRectangle`: все углы 12pt, нижний левый 4pt ("хвост" слева)
- Тонкая граница `Color.primary.opacity(0.08)` — отделяет от фона окна
- `MarkdownTextView` — полная поддержка markdown и кода

**Типографика:**
- Основной текст: SF Pro Text 14pt, lineSpacing 5 (≈1.35× line-height)
- Код: SF Mono 12.5pt, lineSpacing 4
- Apple HIG рекомендует 1.3–1.5× line-height для длинных текстов

### Парсер Markdown

Линейный парсер строк (не RegEx, не AST):
1. Блоки кода: ` ```язык\n...\n``` `
2. Горизонтальный разделитель: `---`
3. Заголовки: `#`, `##`, `###`
4. Пустые строки: разделители параграфов
5. Обычные параграфы: соседние строки объединяются в один блок

---

## 8. Безопасность: API-ключ в Keychain

- `KeychainManager` — статические методы через `kSecClassGenericPassword`
- `SettingsManager` — `@Observable`, читает из Keychain при `init()`, пишет при `apiKey.didSet`
- **Автомиграция**: при первом запуске переносит ключ из UserDefaults в Keychain

---

## 9. Технический долг (актуальный)

| # | Описание | Приоритет | Статус |
|---|---|---|---|
| ТД-4 | ContentView-монолит → разбить на компоненты | 🟠 | ✅ Закрыт |
| ТД-6 | ToolCall-сообщения → типизировать | 🟡 | ✅ Закрыт |
| ТД-7 | Нет стриминга токенов | 🟡 | ✅ Закрыт |
| ТД-UX-PERF | Тормоза UI, 200 МБ памяти | 🔴 | ✅ Закрыт |
| ТД-SEC | API-ключ → Keychain | 🟠 | ✅ Закрыт |
| ТД-TEST | Unit-тесты | 🟡 | ✅ Закрыт |
| ТД-COST | Prompt caching + токенное окно | 🟡 | ✅ Закрыт |
| FIX-DOUBLE-CONTEXT | Двойное сжатие истории | 🔴 | ✅ Закрыт |
| MCP-HELPER | ChappieMCP как дочерний процесс | 🔴 | ✅ Закрыт |
| MCP-WORKSPACE | Хелпер запускался с "/" | 🔴 | ✅ Закрыт |
| MCP-SANDBOX | ENABLE_APP_SANDBOX = YES блокировал bind() | 🔴 | ✅ Закрыт |
| UX-TYPOGRAPHY | Markdown + подсветка синтаксиса + типографика | 🟠 | ✅ Закрыт |

---

## 📚 Changelog

| Date | Change |
|------|--------|
| 2026-05-21 | Initial creation |
| 2026-05-27 | ТД-4: ContentView разбит на компоненты |
| 2026-05-27 | ТД-6: ChatMessage типизирован как enum |
| 2026-05-28 | ТД-7: Стриминг токенов |
| 2026-06-01 | ТД-UX-PERF: visibleMessages, currentToolCall, StatusBarView |
| 2026-06-02 | FIX-DOUBLE-CONTEXT: buildRawNetworkHistory() без сжатия |
| 2026-06-XX | MCP-HELPER/SANDBOX/WORKSPACE |
| 2026-06-XX | ТД-SEC: API-ключ в Keychain |
| 2026-06-XX | Рефакторинг: AI_Docs/ → один файл architecture.md |
| 2026-06-XX | UX-TYPOGRAPHY: MarkdownTextView, CodeBlockView, SyntaxHighlightedText, InlineTextView |
