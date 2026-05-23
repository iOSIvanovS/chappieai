# Карта проекта: Chappie (App Target)

> **Обновлено:** 2026-05-27 — полная синхронизация с реальным состоянием кода.
> **Платформа:** macOS 26+, Swift 6, SwiftUI
> **Архитектура:** MVVM, @Observable, @MainActor

---

## 🗺️ Реальная структура файлов

```text
Chappie/
├── ChappieApp.swift              # @main, точка входа, WindowGroup → ContentView
├── ContentView.swift             # Корневой экран: сайдбар + чат + ввод + тулбар (монолит)
│                                 # Содержит private struct MessageBubble
├── ChappieViewModel.swift        # Главная ViewModel (@Observable, @MainActor)
│                                 # Содержит также public struct ChatMessage
├── Settings/
│   ├── SettingsManager.swift     # Хранение API-ключа в UserDefaults (@Observable, singleton)
│   └── SettingsView.swift        # Sheet настроек: ввод, валидация, сохранение ключа
├── Assets.xcassets/
│   ├── AppIcon.appiconset/       # Иконка приложения
│   ├── AccentColor.colorset/     # Акцентный цвет
│   └── Chappie.imageset/         # Фоновое изображение (Chappie.jpg) — opacity 0.5 в UI
└── AI_Docs/
    ├── semantic.json             # Семантическая память App-таргета (ключ → MemoryRecord)
    ├── architecture.md           # Архитектурная документация UI-слоя
    └── project_map.md            # Этот файл
```

---

## 📝 Детальное описание файлов

### 1. `ChappieApp.swift`
- **Назначение:** Точка входа приложения (`@main`).
- **Содержимое:** `struct ChappieApp: App` с `WindowGroup { ContentView() }`.
- **Импорты:** `SwiftUI`, `ChappieCore`.
- **Почему минимален:** Точка входа должна быть предсказуемой. Вся логика — в ViewModel.

### 2. `ContentView.swift`
- **Назначение:** Корневой SwiftUI-экран. Весь UI приложения.
- **Архитектура:** `NavigationSplitView` с сайдбаром и основной областью.
- **Содержит:**
  - `private struct MessageBubble` — пузырёк сообщения (текст + стоимость).
  - `struct ContentView` — главный экран.
- **Состояние:** `@State private var viewModel = ChappieViewModel()` — ViewModel создаётся здесь.
- **Технический долг:** Весь UI в одном файле — нужно разбить на компоненты (ТД-4).
- **Ключевые решения:**
  - `ScrollViewReader` для автопрокрутки к последнему сообщению.
  - Фоновое изображение `Image("Chappie")` с `opacity(0.5)`.
  - Кнопка ⚙️ в тулбаре — оранжевая если API-ключ не задан.
  - `TextField` с `axis: .vertical` для многострочного ввода (1–10 строк).

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

### 4. `Settings/SettingsManager.swift`
- **Назначение:** Единственное место хранения и валидации API-ключа.
- **Тип:** `@Observable final class`, singleton (`SettingsManager.shared`).
- **Хранилище:** `UserDefaults` по ключу `"aitunnel_api_key"`.
- **Валидация:** `isApiKeyValid` — ключ начинается с `"sk-aitunnel-"` и длина > 20 символов.
- **Почему не Keychain:** UserDefaults выбран для простоты. Keychain — следующий шаг (ТД-5).

### 5. `Settings/SettingsView.swift`
- **Назначение:** Sheet настроек для ввода API-ключа.
- **Открывается:** По кнопке ⚙️ в тулбаре или из сайдбара (при отсутствии ключа).
- **Функционал:**
  - Поле ввода с переключением видимости (SecureField ↔ TextField).
  - Индикатор валидности в реальном времени.
  - Кнопка "Сохранить" → вызывает `onApiKeyChanged: (String) -> Void`.
- **Коллбэк:** `onApiKeyChanged` → `viewModel.updateApiKey(_:)` — пересоздаёт клиент.

### 6. `Assets.xcassets/`
- **AppIcon.appiconset:** Иконка приложения.
- **AccentColor.colorset:** Системный акцентный цвет (используется в кнопках).
- **Chappie.imageset/Chappie.jpg:** Фоновое изображение — портрет робота Чаппи. Отображается в `ContentView` с `opacity(0.5)` как декоративный фон.

---

## 🧩 Таблица Key Files Description

| File | Purpose | Тип |
|------|---------|-----|
| `ChappieApp.swift` | Точка входа. Минимальный bootstrap. | `@main struct` |
| `ContentView.swift` | Весь UI приложения (монолит). NavigationSplitView. | `struct View` |
| `ChappieViewModel.swift` | Единственный ViewModel. Координирует UI и ChappieCore. | `@Observable @MainActor class` |
| `Settings/SettingsManager.swift` | Хранение и валидация API-ключа. | `@Observable class`, singleton |
| `Settings/SettingsView.swift` | Sheet для ввода API-ключа. | `struct View` |
| `Assets.xcassets/` | Иконки, фоны, цвета. | Ресурсы |
| `AI_Docs/semantic.json` | Долгосрочная память App-таргета. | JSON (MemoryRecord) |
| `AI_Docs/architecture.md` | Архитектурная документация. | Markdown |
| `AI_Docs/project_map.md` | Этот файл. | Markdown |

---

## 🔌 Public API (что используется из ChappieCore)

```swift
// Импортируется в ChappieViewModel.swift
import ChappieCore

// Типы, используемые напрямую:
AITunnelClient(apiKey: String)              // Сетевой клиент
FileSystemManager(workspaceURL: URL)        // Файловая система
MemoryManager(workspaceURL: URL)            // Долгосрочная память
ToolExecutionService(fileSystem:memoryManager:)  // Реестр инструментов
AIOrchestrator(aiClient:toolService:fileSystem:) // Главный оркестратор
ChatHistoryManager(workspaceURL: URL?)      // История чата
AppConfig.shared                            // Конфигурация (лимиты, таймауты)

// Типы данных:
AIMessage(role:content:)                    // Сообщение для API
AIOrchestratorResult                        // Результат: ответ + стоимость + баланс
MemoryScope                                 // .project / .global
ChappieError                                // Типизированные ошибки
```

---

## 🔄 Жизненный цикл сессии

1. **Запуск приложения**
   - `ChappieApp` → `ContentView` → `ChappieViewModel.init()`.
   - ViewModel читает API-ключ из `SettingsManager`.
   - ViewModel вызывает `loadWorkspaceWithSecurityScope()` — восстанавливает воркспейс.
   - Если воркспейс найден → `initializeServices(for:)` → стек сервисов готов.
   - Загружается история чата из `ChatHistoryManager`.

2. **Выбор воркспейса**
   - Пользователь нажимает "Выбрать папку проекта..." → `NSOpenPanel`.
   - `setWorkspace(_:)` → `initializeServices(for:)` + `saveWorkspaceWithSecurityScope(_:)`.
   - `MemoryManager.initializeWorkspaceMemory()` — создаёт AI_Docs если нет.

3. **Отправка сообщения**
   - `send(prompt:)` → проверка ключа → добавление в историю → `isThinking = true`.
   - Smart Pruning истории → передача в `orchestrator.process()`.
   - Коллбэк `onToolCall` → добавление "🛠 Выполняю: ..." в UI.
   - Финальный ответ → добавление в историю с ценой → `isThinking = false`.

4. **Смена API-ключа**
   - `SettingsView` → `SettingsManager.saveApiKey()` → коллбэк → `viewModel.updateApiKey(_:)`.
   - Пересоздаются `AITunnelClient` и `AIOrchestrator` — без перезапуска приложения.

---

## 🚧 Known Issues & TODOs

- [ ] **ТД-4: Разбить ContentView на компоненты** — `ChatView`, `InputView`, `SidebarView`, `ToolCallView`.
- [ ] **ТД-5: Перенести API-ключ в Keychain** — UserDefaults небезопасен для секретов.
- [ ] **ТД-6: Типизировать ToolCall-сообщения** — сейчас это `ChatMessage` с эмодзи-префиксом `"🛠"`.
- [ ] **ТД-7: Стриминг токенов** — сейчас блокирующий запрос, пользователь ждёт весь ответ.
- [ ] **ТД-8: Unit-тесты для ViewModel** — `send(prompt:)`, `stripCodeBlocks(from:)`, bookmark recovery.
- [ ] **Локализация** — все строки захардкожены на русском.
- [ ] **Поддержка тёмной/светлой темы** — фоновое изображение может выглядеть по-разному.
- [ ] **UX при ошибках воркспейса** — нет понятного состояния если bookmark устарел.

---

## 📚 Changelog

| Date | Change | Author |
|------|--------|--------|
| 2026-05-21 | Initial creation | Chappie AI |
| 2026-05-23 | Expanded with real file descriptions | Chappie AI |
| 2026-05-27 | Полная переработка: синхронизация с реальным кодом. Добавлены Settings/, реальная структура ViewModel, убраны несуществующие файлы | Chappie AI |
