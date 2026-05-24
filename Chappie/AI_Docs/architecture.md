<!--
  Chappie/AI_Docs/architecture.md

  ДОКУМЕНТ АРХИТЕКТУРЫ — CHAPPIE APP (UI LAYER)

  Обновлён: MCP Helper Launcher — исправлен воркспейс "/" (2026-06-XX)
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
│   ├── main.swift                      # Точка входа хелпера, запускает MCPUnixServer
│   ├── MCPHTTPServer.swift             # Unix Domain Socket сервер, диспетчер инструментов
│   ├── GitTools.swift                  # git_status, git_diff, git_add, git_commit, git_log, git_reset
│   └── BuildTools.swift               # build_project, run_tests, read_build_log
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

**ПРОБЛЕМА (была):** `ChappieApp.onAppear` вызывал `MCPHelperLauncher.shared.launch()` без пути.
В этот момент воркспейс ещё не восстановлен из bookmark.
`FileManager.default.currentDirectoryPath` возвращал `/` (корень ФС).
Хелпер запускался с воркспейсом `/` → git не находил репозиторий → все команды падали.

**РЕШЕНИЕ:** Хелпер запускается ТОЛЬКО когда путь к воркспейсу известен:
- `loadWorkspaceWithSecurityScope()` — после успешного восстановления bookmark → `launch(workspacePath: url.path)`
- `setWorkspace()` — при ручном выборе папки → `restartWithWorkspace(url)`
- `ChappieApp.onAppear` — НЕ запускает хелпер (убрано).

### App Sandbox

**ПРОБЛЕМА (была):** `ENABLE_APP_SANDBOX = YES` в pbxproj блокировал `bind()` для дочернего процесса.
**РЕШЕНИЕ:** `ENABLE_APP_SANDBOX = NO` в Debug и Release конфигурациях таргета Chappie.
Сокет располагается в `/tmp/com.chappie.mcp.sock` — стандартное место для Unix Domain Sockets.

### kSocketPath — default argument

**ПРОБЛЕМА (была):** `private let kSocketPath = "..."` как default argument в `public init` — компилятор
отклоняет: "internal let cannot be referenced from a default argument value".
**РЕШЕНИЕ:** строковый литерал `"/tmp/com.chappie.mcp.sock"` прямо в default argument.

### lazy vs @Observable

**ПРОБЛЕМА (была):** `lazy var socketPath` в `@Observable` классе — компилятор падает:
"init accessor cannot refer to property '_socketPath'".
**ПРИЧИНА:** `@Observable` макрос генерирует init accessor для каждого хранимого свойства,
и `lazy` несовместимо с этой генерацией.
**РЕШЕНИЕ:** вычислять `socketPath` в `init()` и хранить как обычное `var`.

### Расположение бинарника

```
Chappie.app/
└── Contents/
    ├── MacOS/
    │   └── Chappie          # Основной бинарник
    └── Helpers/
        └── ChappieMCP       # Helper executable (Copy Files Build Phase)
```

### MCPHelperLauncher — ключевые решения

| Решение | Причина |
|---|---|
| Singleton `shared` | Один хелпер на всё приложение, управление из любого места |
| `@MainActor` | Process и @Observable свойства — только главный поток |
| `terminationHandler` через `Task { @MainActor }` | Handler вызывается на фоновом потоке |
| `applicationWillTerminate` через NSApplicationDelegate | SwiftUI App не даёт хука на завершение |
| `SIGTERM` (код 15) — не считается крашем | Это наш собственный terminate() |
| `Bundle.main.url(forAuxiliaryExecutable:)` + fallback | Стандартный API + ручной путь для надёжности |
| Запуск только из ViewModel, не из ChappieApp | Путь к воркспейсу известен только в ViewModel |

---

## 4. КРИТИЧЕСКИ ВАЖНО: Кто строит контекстное окно истории

### Проблема (была до FIX-DOUBLE-CONTEXT)

История сжималась **дважды** с **разными параметрами**:

1. `ChappieViewModel.buildNetworkHistory()` — tokenBudget=**30,000**, recentFullCount=**6**, summaryThreshold=**200**
2. `AIOrchestrator.buildContextWindow()` — tokenBudget=**12,000**, recentFullCount=**3**, summaryThreshold=**400**

**Результат: 21,000+ токенов на запрос вместо ожидаемых 5,000-7,000.**

### Решение (FIX-DOUBLE-CONTEXT)

**Единственный источник истины для логики сжатия — `AIOrchestrator.buildContextWindow()`.**

| Компонент | Ответственность |
|---|---|
| `ChappieViewModel.buildRawNetworkHistory()` | ТОЛЬКО конвертация `ChatMessage` → `AIMessage`. Никакого сжатия! |
| `AIOrchestrator.buildContextWindow()` | Токенный бюджет, замена на summary, обрезка. Читает параметры из `AppConfig`. |
| `AppConfig.shared` | Единственное место где живут `tokenBudget`, `recentFullMessages`, `summaryThreshold`. |

---

## 5. Оптимизация производительности UI (ТД-UX-PERF)

### visibleMessages — фильтрация и лимит

```swift
var visibleMessages: [ChatMessage] {
    let onlyMessages = messages.filter { if case .message = $0 { return true }; return false }
    return Array(onlyMessages.suffix(30))   // макс. 30 .message в ленте
}
```

### currentToolCall — строка состояния

```swift
self.currentToolCall = "\(toolName) → \(shortPath)"  // во время работы
self.currentToolCall = nil                             // после завершения
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
ChatScrollView.streamingBubble     → Text(streamingText) + BlinkingCursor
```

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
| MCP-HELPER | ChappieMCP как дочерний процесс + MCPHelperLauncher | 🔴 | ✅ Закрыт |
| MCP-WORKSPACE | Хелпер запускался с "/" → git не работал | 🔴 | ✅ Закрыт |
| MCP-SANDBOX | ENABLE_APP_SANDBOX = YES блокировал bind() | 🔴 | ✅ Закрыт |

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
| 2026-06-XX | MCP-HELPER: MCPHelperLauncher + ChappieAppDelegate + ChappieMCP Xcode target |
| 2026-06-XX | MCP-SANDBOX: ENABLE_APP_SANDBOX = NO, /tmp/ сокет, lazy→init(), kSocketPath→литерал |
| 2026-06-XX | MCP-WORKSPACE: хелпер запускается из loadWorkspaceWithSecurityScope(), не из onAppear |
