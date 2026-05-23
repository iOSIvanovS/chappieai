# Карта проекта: Chappie (App Target)

> **Обновлено:** 2026-05-27 — Этап 4 закрыт: ТД-4 снят, Views разбиты на компоненты.
> **Платформа:** macOS 26+, Swift 6, SwiftUI
> **Архитектура:** MVVM, @Observable, @MainActor

---

## 🗺️ Реальная структура файлов

```text
Chappie/
├── ChappieApp.swift                    # @main, точка входа, WindowGroup → ContentView
├── ContentView.swift                   # Чистый "дирижёр": собирает компоненты, делегирует логику
│                                       # @State var viewModel, @State var showSettings, @State var currentPrompt
├── ChappieViewModel.swift              # Главная ViewModel (@Observable, @MainActor)
│                                       # Содержит также public struct ChatMessage
├── Views/
│   ├── Chat/
│   │   ├── MessageBubbleView.swift     # Пузырёк одного сообщения (текст + стоимость)
│   │   └── ChatScrollView.swift        # Лента сообщений с автоскроллом + спиннер
│   ├── Input/
│   │   └── InputBarView.swift          # Панель ввода: TextField + кнопка отправки
│   ├── Sidebar/
│   │   └── SidebarView.swift           # Боковая панель: воркспейс + предупреждения
│   └── Toolbar/
│       └── ToolbarContent.swift        # Тулбар: баланс + кнопка настроек
├── Settings/
│   ├── SettingsManager.swift           # Хранение API-ключа в UserDefaults (@Observable, singleton)
│   └── SettingsView.swift              # Sheet настроек: ввод, валидация, сохранение ключа
├── Assets.xcassets/
│   ├── AppIcon.appiconset/             # Иконка приложения
│   ├── AccentColor.colorset/           # Акцентный цвет
│   └── Chappie.imageset/               # Фоновое изображение (Chappie.jpg) — opacity 0.5 в UI
└── AI_Docs/
    ├── semantic.json                   # Семантическая память App-таргета (ключ → MemoryRecord)
    ├── architecture.md                 # Архитектурная документация UI-слоя
    └── project_map.md                  # Этот файл
```

---

## 📝 Детальное описание файлов

### 1. `ChappieApp.swift`
- **Назначение:** Точка входа приложения (`@main`).
- **Содержимое:** `struct ChappieApp: App` с `WindowGroup { ContentView() }`.
- **Импорты:** `SwiftUI`, `ChappieCore`.
- **Почему минимален:** Точка входа должна быть предсказуемой. Вся логика — в ViewModel.

### 2. `ContentView.swift`
- **Назначение:** Чистый "дирижёр". Собирает компоненты, прокидывает данные из ViewModel.
- **Архитектура:** `NavigationSplitView` → `SidebarView` + `VStack(ChatScrollView + InputBarView)`.
- **НЕ содержит:** бизнес-логику, рендеринг пузырей, логику скролла — всё делегировано компонентам.
- **Состояние:**
  - `@State private var viewModel = ChappieViewModel()`
  - `@State private var showSettings = false`
  - `@State private var currentPrompt = ""`
- **Приватные методы:**
  - `selectWorkspace()` — открывает `NSOpenPanel` (UI-операция, не бизнес-логика).
  - `sendMessage()` — guard + `viewModel.send()` + сброс поля.
- **Background:** `Image("Chappie")` с opacity 0.5 поверх всего окна.

### 3. `ChappieViewModel.swift`
- **Назначение:** Единственный ViewModel. Мост между UI и ChappieCore.
- **Тип:** `@Observable @MainActor final class`.
- **Содержит также:** `public struct ChatMessage: Identifiable, Hashable, Codable` (id, isUser, text, cost).
- **Ключевые свойства:**
  - `messages: [ChatMessage]` — история чата. `didSet` → `saveMessages()`.
  - `isThinking: Bool` — флаг активного AI-запроса.
  - `workspaceURL: URL?` — текущий воркспейс.
  - `currentBalance: Double?` — баланс AITunnel. `didSet` → UserDefaults.
- **Ключевые методы:**
  - `send(prompt:)` — запуск агентного цикла.
  - `setWorkspace(_:)` — подключение новой папки.
  - `updateApiKey(_:)` — смена ключа без перезапуска.
  - `initializeServices(for:)` — ЕДИНСТВЕННОЕ место создания стека сервисов.
  - `clearHistory()` — очистка с приветствием.
  - `stripCodeBlocks(from:)` — оптимизация контекста (Smart Pruning).
  - `saveWorkspaceWithSecurityScope(_:)` — сохранение Bookmark.
  - `loadWorkspaceWithSecurityScope()` — восстановление Bookmark при старте.

### 4. `Views/Chat/MessageBubbleView.swift`
- **Назначение:** Рендеринг одного сообщения в чате.
- **Тип:** `struct MessageBubbleView: View`.
- **Входные данные:** `msg: ChatMessage`.
- **Поведение:**
  - Сообщения пользователя — справа, акцентный цвет, белый текст.
  - Сообщения Чаппи — слева, цвет фона окна, основной цвет текста.
  - Если `msg.cost != nil` — показывает "🪙 X.XX ₽" снизу справа.
  - `textSelection(.enabled)` — пользователь может копировать текст.
- **Preview:** `#Preview` с тестовыми сообщениями пользователя и Чаппи.

### 5. `Views/Chat/ChatScrollView.swift`
- **Назначение:** Прокручиваемая лента сообщений.
- **Тип:** `struct ChatScrollView: View`.
- **Входные данные:** `messages: [ChatMessage]`, `isThinking: Bool`.
- **Поведение:**
  - Пустой чат → приветственное сообщение.
  - `isThinking = true` → показывает `ProgressView` в конце ленты.
  - Автоскролл к `"BottomSpacer"` при изменении `messages` или `isThinking`.
  - Анимация `.easeOut(duration: 0.3)` при скролле.
- **Preview:** `#Preview` с набором тестовых сообщений.

### 6. `Views/Input/InputBarView.swift`
- **Назначение:** Панель ввода сообщения.
- **Тип:** `struct InputBarView: View`.
- **Входные данные:** `prompt: Binding<String>`, `isWorkspaceSelected: Bool`, `isThinking: Bool`, `onSend: () -> Void`.
- **Поведение:**
  - `TextField` с `axis: .vertical`, лимит 1–10 строк.
  - Enter → `onSend()`. ⌥+Enter → перенос строки (стандартное поведение macOS).
  - Заблокирован если воркспейс не выбран или `isThinking = true`.
  - Кнопка отправки заблокирована если `prompt` пуст.
- **Preview:** `#Preview` с двумя состояниями: активный и заблокированный.

### 7. `Views/Sidebar/SidebarView.swift`
- **Назначение:** Боковая панель с контекстом и предупреждениями.
- **Тип:** `struct SidebarView: View`.
- **Входные данные:** `workspaceURL: URL?`, `isApiKeyValid: Bool`, `onSelectWorkspace: () -> Void`, `onOpenSettings: () -> Void`.
- **Поведение:**
  - Если воркспейс выбран → показывает `lastPathComponent` + кнопку "Сменить".
  - Если не выбран → кнопка "Выбрать папку проекта...".
  - Если `!isApiKeyValid` → секция "⚠️ Внимание" с кнопкой настроек.
- **Preview:** `#Preview` с двумя состояниями: с воркспейсом и без.

### 8. `Views/Toolbar/ToolbarContent.swift`
- **Назначение:** Контент тулбара главного окна.
- **Тип:** `struct ChappieToolbarContent: ToolbarContent`.
- **Входные данные:** `balance: Double?`, `isApiKeyValid: Bool`, `onOpenSettings: () -> Void`.
- **Поведение:**
  - Если `balance != nil` → таблетка с "💳 X.XX ₽".
  - Кнопка ⚙️ — оранжевая если `!isApiKeyValid`.
- **Preview:** `#Preview` с двумя состояниями: с балансом и без.

### 9. `Settings/SettingsManager.swift`
- **Назначение:** Единственное место хранения и валидации API-ключа.
- **Тип:** `@Observable final class`, singleton (`SettingsManager.shared`).
- **Хранилище:** `UserDefaults` по ключу `"aitunnel_api_key"`.
- **Валидация:** `isApiKeyValid` — ключ начинается с `"sk-aitunnel-"` и длина > 20 символов.

### 10. `Settings/SettingsView.swift`
- **Назначение:** Sheet настроек для ввода API-ключа.
- **Тип:** `struct SettingsView: View`.
- **Функционал:**
  - Поле ввода с переключением видимости (SecureField ↔ TextField).
  - Индикатор валидности в реальном времени.
  - Кнопка "Сохранить" → вызывает `onApiKeyChanged: (String) -> Void`.
- **Коллбэк:** `onApiKeyChanged` → `viewModel.updateApiKey(_:)` — пересоздаёт клиент.

---

## 🧩 Таблица Key Files

| File | Purpose | Тип |
|------|---------|-----|
| `ChappieApp.swift` | Точка входа. Минимальный bootstrap. | `@main struct` |
| `ContentView.swift` | Чистый дирижёр. Собирает компоненты. | `struct View` |
| `ChappieViewModel.swift` | Единственный ViewModel. Координирует UI и ChappieCore. | `@Observable @MainActor class` |
| `Views/Chat/MessageBubbleView.swift` | Пузырёк одного сообщения. | `struct View` |
| `Views/Chat/ChatScrollView.swift` | Лента сообщений с автоскроллом. | `struct View` |
| `Views/Input/InputBarView.swift` | Панель ввода. | `struct View` |
| `Views/Sidebar/SidebarView.swift` | Боковая панель. | `struct View` |
| `Views/Toolbar/ToolbarContent.swift` | Контент тулбара. | `struct ToolbarContent` |
| `Settings/SettingsManager.swift` | Хранение и валидация API-ключа. | `@Observable class`, singleton |
| `Settings/SettingsView.swift` | Sheet для ввода API-ключа. | `struct View` |
| `Assets.xcassets/` | Иконки, фоны, цвета. | Ресурсы |
| `AI_Docs/semantic.json` | Долгосрочная память App-таргета. | JSON (MemoryRecord) |

---

## 🔌 Public API (что используется из ChappieCore)

```swift
// Импортируется в ChappieViewModel.swift
import ChappieCore

AITunnelClient(apiKey: String)
FileSystemManager(workspaceURL: URL)
MemoryManager(workspaceURL: URL)
ToolExecutionService(fileSystem:memoryManager:)
AIOrchestrator(aiClient:toolService:fileSystem:)
ChatHistoryManager(workspaceURL: URL?)
AppConfig.shared

AIMessage(role:content:)
AIOrchestratorResult
MemoryScope
ChappieError
```

---

## 🔄 Жизненный цикл сессии

1. **Запуск** → `ChappieViewModel.init()` → читает ключ из `SettingsManager` → `loadWorkspaceWithSecurityScope()` → `initializeServices(for:)` → загружает историю.
2. **Выбор воркспейса** → `NSOpenPanel` в `ContentView.selectWorkspace()` → `viewModel.setWorkspace(_:)` → `initializeServices(for:)` + `MemoryManager.initializeWorkspaceMemory()`.
3. **Отправка сообщения** → `InputBarView.onSend()` → `ContentView.sendMessage()` → `viewModel.send(prompt:)` → Smart Pruning → `orchestrator.process()` → коллбэк `onToolCall` → финальный ответ.
4. **Смена ключа** → `SettingsView` → `SettingsManager.saveApiKey()` → `onApiKeyChanged` → `viewModel.updateApiKey(_:)` → пересоздание `AITunnelClient` + `AIOrchestrator`.

---

## 🚧 Known Issues & TODOs

| # | Описание | Статус |
|---|---|---|
| ТД-4 | ContentView-монолит → разбить на компоненты | ✅ Закрыт (Этап 4) |
| ТД-5 | API-ключ в UserDefaults → перенести в Keychain | 🟡 Открыт |
| ТД-6 | ToolCall-сообщения как ChatMessage с эмодзи-префиксом → типизировать | 🟡 Открыт |
| ТД-7 | Нет стриминга токенов — пользователь ждёт полного ответа | 🟡 Открыт |
| ТД-8 | Нет Unit-тестов для ViewModel | 🟡 Открыт |

---

## 📚 Changelog

| Date | Change |
|------|--------|
| 2026-05-21 | Initial creation |
| 2026-05-23 | Expanded with real file descriptions |
| 2026-05-27 | Полная переработка: синхронизация с реальным кодом. Добавлены Settings/. |
| 2026-05-27 | Этап 4: ContentView разбит на компоненты. Добавлены Views/Chat, Views/Input, Views/Sidebar, Views/Toolbar. ТД-4 закрыт. |
