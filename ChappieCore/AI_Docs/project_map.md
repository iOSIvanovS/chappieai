# Карта проекта: ChappieCore (Library Target)

> **Обновлено:** 2026-05-27 — полная синхронизация с реальным состоянием кода.
> **Тип:** Swift Package (Library Target)
> **Платформа:** macOS 15+, Swift 6 (Full Concurrency Checking)
> **Версия:** `coreVersion = "1.0.0"` (из `ChappieCore.swift`)

---

## 🗺️ Реальная структура файлов

```text
ChappieCore/
├── Package.swift                           # SPM манифест: swift-tools-version, платформы, таргеты
├── AI_Docs/
│   ├── semantic.json                       # Семантическая память Library-таргета
│   ├── architecture.md                     # Архитектурная документация (детальные схемы)
│   └── project_map.md                      # Этот файл
└── Sources/ChappieCore/
    ├── ChappieCore.swift                   # Фасад пакета: документация API + coreVersion
    ├── Models/
    │   ├── AITunnelModels.swift            # Codable-модели для API AITunnel
    │   ├── AppConfig.swift                 # Централизованная конфигурация (struct, singleton)
    │   └── ChappieError.swift              # Единый перечислитель ошибок (LocalizedError)
    └── Services/
        ├── AITunnelClient.swift            # HTTP-клиент (struct, Sendable) — НЕ actor
        ├── AIOrchestrator.swift            # Агентный цикл (actor)
        ├── ToolExecutionService.swift      # Реестр и исполнитель инструментов (actor)
        ├── FileSystemManager.swift         # Безопасная работа с файлами (actor)
        ├── MemoryManager.swift             # Долгосрочная память (actor)
        └── ChatHistoryManager.swift        # История чата (final class, Sendable)
```

---

## 📝 Детальное описание файлов

### 📦 `Package.swift`
- **Назначение:** SPM манифест.
- **Ключевые настройки:** `swift-tools-version: 6.0`, `swiftLanguageVersions: [.v6]`, `platforms: [.macOS(.v15)]`.
- **Swift 6:** Full Strict Concurrency Checking включён — компилятор гарантирует отсутствие гонок данных.
- **ВАЖНО:** Нет тестового таргета — технический долг (ТД-8).

---

### 🗂️ Модели данных (`Models/`)

#### `AppConfig.swift`
- **Тип:** `public struct AppConfig: Codable, Equatable, Sendable`
- **Синглтон:** `public static let shared = AppConfig()`
- **Параметры:**

| Параметр | Значение | Назначение |
|---|---|---|
| `maxOrchestratorSteps` | 100 | Лимит итераций агентного цикла |
| `maxHistoryMessages` | 15 | Лимит сообщений в контексте API |
| `requestTimeoutSeconds` | 300 | Таймаут HTTP-запроса (5 минут) |
| `connectionTimeoutSeconds` | 30 | Таймаут установки соединения |

- **Принцип:** Единственный источник всех "магических чисел". Никаких захардкоженных значений в других файлах.

#### `ChappieError.swift`
- **Тип:** `public enum ChappieError: LocalizedError, Sendable`
- **Кейсы:**
  - `networkError(String)` — сетевые проблемы, таймауты
  - `fileSystemError(String)` — ошибки файловой системы, Path Traversal
  - `parsingError(String)` — ошибки JSON сериализации/десериализации
  - `memoryError(String)` — ошибки работы с памятью
  - `aiContextLimitExceeded` — превышен контекст модели (HTTP 413)
  - `unknown(String)` — прочие ошибки (включая превышение maxOrchestratorSteps)

#### `AITunnelModels.swift`
- **Назначение:** Все Codable/Sendable структуры для работы с API AITunnel.
- **Модели запроса:**
  - `AITunnelRequest` — тело POST-запроса (model, messages, temperature, tools?)
  - `AIMessage` — сообщение (role, content?, tool_calls?, tool_call_id?, name?)
  - `AITool` / `AIFunctionDefinition` / `AIToolParameters` / `AIToolProperty` — схема инструментов
- **Модели ответа:**
  - `AITunnelResponse` — ответ API (id?, choices, usage?)
  - `AIChoice` — один вариант ответа (message, finish_reason?)
  - `AIUsage` — статистика (prompt_tokens?, completion_tokens?, total_tokens?, cost_rub?, balance?)
- **Модели вызовов инструментов:**
  - `AIToolCall` — вызов инструмента моделью (id, type, function)
  - `AIToolCallFunction` — имя и JSON-аргументы вызова

---

### ⚙️ Сервисы (`Services/`)

#### `AITunnelClient.swift`
- **Тип:** `public struct AITunnelClient: Sendable` ← ВАЖНО: struct, не actor!
- **Почему struct:** Нет изменяемого состояния — все свойства `let`. Автоматически `Sendable`.
- **Endpoint:** `https://api.aitunnel.ru/v1/chat/completions`
- **Свойства:**
  - `apiKey: String` — ключ авторизации (Bearer)
  - `modelName: String` — по умолчанию `"claude-sonnet-4.6"`
  - `urlSession: URLSession` — кастомная, с таймаутом 300с из AppConfig
- **Метод:** `sendRequest(systemPrompt:chatHistory:tools:) async throws -> (AIMessage, Double?, Double?)`
- **Обработка ошибок:**
  - `NSURLErrorTimedOut` → `ChappieError.networkError` с советом разбить задачу
  - HTTP 4xx/5xx → парсинг тела + `ChappieError.networkError`
  - HTTP 413 / "context" в теле → `ChappieError.aiContextLimitExceeded`

#### `AIOrchestrator.swift`
- **Тип:** `public actor AIOrchestrator`
- **Инициализатор:** `init(aiClient:toolService:fileSystem:config:)` — `config` по умолчанию `.shared`
- **Системный промпт:** Хранится как `private let systemPrompt` — личность и правила Чаппи.
- **Метод:** `process(prompt:history:onToolCall:) async throws -> AIOrchestratorResult`
- **Результат:** `AIOrchestratorResult` (finalResponse, totalCost?, newBalance?)
- **Защита от зацикливания:** `executedToolSignatures: Set<String>` — повторный вызов с теми же аргументами возвращает СИСТЕМНУЮ ОШИБКУ вместо реального выполнения.
- **Лимит:** `config.maxOrchestratorSteps` — читается из AppConfig, не захардкожен.

#### `ToolExecutionService.swift`
- **Тип:** `public actor ToolExecutionService`
- **8 инструментов** в `availableTools: [AITool]`:
  - Файловая система: `list_files`, `read_file`, `write_file`, `delete_file`
  - Память: `memorize`, `recall`, `search_memory`, `delete_memory`
- **Метод:** `execute(call: AIToolCall) async -> String`
- **Парсинг аргументов:** `JSONDecoder().decode([String: String].self, from: argsData)`
- **ВАЖНО:** Нет инструмента `delegate_task` — монофизитная архитектура, один агент.

#### `FileSystemManager.swift`
- **Тип:** `public actor FileSystemManager`
- **Корень:** `public let workspaceURL: URL`
- **Защита от Path Traversal:** `validateAndResolvePath(_:)` — стандартизация + проверка prefix.
- **API:** `listFiles()`, `readFile(at:)`, `writeFile(at:content:)`, `deleteFile(at:)`
- **Кодировка:** UTF-8 для всех файловых операций.
- **Атомарность:** `write(to:atomically:encoding:)` с `atomically: true`.

#### `MemoryManager.swift`
- **Тип:** `public actor MemoryManager`
- **Ключевые типы:**
  - `MemoryRecord: Codable, Sendable` — (type, timestamp, data: String)
  - `MemoryScope: String, Codable, Sendable` — .project / .global
  - `WorkspaceTarget: Sendable` — описание таргета с путями к AI_Docs
  - `TargetKind: Sendable` — .appTarget / .library
  - `TargetScanResult: Sendable` — результат сканирования файлов таргета
- **Глобальная память:** `~/Documents/Chappie/semantic.json`
- **Память таргетов:** `<workspace>/<TargetName>/AI_Docs/semantic.json`
- **Инициализация:** `initializeWorkspaceMemory()` — идемпотентна, защищена флагом `isInitialized`.
- **Ленивая инициализация:** `ensureInitialized()` — вызывается перед каждой операцией.
- **Классификация таргетов:** App-таргет = содержит `*App.swift`. Library = всё остальное.
- **Фильтрация:** Исключает `.xcodeproj`, `.xcworkspace` (директории с расширением).
- **Миграция:** `migrateOldRootAIDocs()` — переносит данные из корневого AI_Docs в таргет.

#### `ChatHistoryManager.swift`
- **Тип:** `public final class ChatHistoryManager: Sendable` ← НЕ actor!
- **Почему class:** Нужен синглтон `shared`. Почему не actor: все свойства `let`, Sendable достигается без actor.
- **Синглтон:** `public static let shared = ChatHistoryManager(workspaceURL: nil)` — фолбэк без воркспейса.
- **Пути:**
  - С воркспейсом: `<workspace>/AI_Docs/chat_history.json`
  - Без воркспейса: `~/Documents/Chappie/global_chat_history.json`
- **Generic API:** `loadMessages<T: Codable>()` и `saveMessages<T: Codable>(_:)` — не зависит от `ChatMessage`.
- **Миграция:** `migrateIfNeeded(to:)` — копирует из старого `chappie_chat_history.json`.

---

## 🔌 Public API (интерфейс для UI-слоя)

```swift
import ChappieCore

// 1. Конфигурация (читается автоматически)
let config = AppConfig.shared
config.maxOrchestratorSteps  // 100
config.requestTimeoutSeconds // 300.0

// 2. Инициализация стека сервисов
let aiClient = AITunnelClient(apiKey: "sk-aitunnel-...")
let fileSystem = FileSystemManager(workspaceURL: workspaceURL)
let memoryManager = MemoryManager(workspaceURL: workspaceURL)
await memoryManager.initializeWorkspaceMemory()  // Создаёт AI_Docs структуру
let toolService = ToolExecutionService(fileSystem: fileSystem, memoryManager: memoryManager)
let orchestrator = AIOrchestrator(aiClient: aiClient, toolService: toolService, fileSystem: fileSystem)

// 3. Запуск агентного цикла
let result = try await orchestrator.process(
    prompt: "Добавь тест для FileSystemManager",
    history: [AIMessage(role: "user", content: "предыдущее сообщение")],
    onToolCall: { toolName, targetPath in
        print("🛠 \(toolName) → \(targetPath)")
    }
)
print(result.finalResponse)  // Финальный ответ
print(result.totalCost ?? 0) // Стоимость в рублях
print(result.newBalance ?? 0) // Новый баланс

// 4. История чата
let historyManager = ChatHistoryManager(workspaceURL: workspaceURL)
let messages: [ChatMessage] = historyManager.loadMessages()
historyManager.saveMessages(messages)

// 5. Память (напрямую из UI если нужно)
await memoryManager.saveMemory(key: "api_key_format", type: "rule",
                               jsonString: "{\"format\": \"sk-aitunnel-...\"}")
let value = await memoryManager.readMemory(key: "api_key_format")
```

---

## ⚠️ Рекомендации по развитию ядра

1. **Новые инструменты:** Регистрировать в `availableTools` в `ToolExecutionService.swift` и добавлять `case` в `execute(call:)`. Оба места в одном файле.

2. **Новые сервисы с состоянием:** Объявлять как `actor`. Без состояния — `struct` с `Sendable`.

3. **Новые параметры конфигурации:** Добавлять только в `AppConfig.swift`. Никаких захардкоженных чисел в других файлах.

4. **Обновление карт проектов:** После значимых изменений структуры вызывать `memoryManager.refreshProjectMap(forTarget: "ChappieCore")`.

5. **Тесты:** Добавить тестовый таргет в `Package.swift` (ТД-8). Особенно важно покрыть `FileSystemManager.validateAndResolvePath()` — защита безопасности.

---

## 🚧 Known Issues & TODOs

- [ ] **ТД-7: Стриминг токенов** — `AITunnelClient.sendRequest()` делает блокирующий запрос. Нужен SSE-стриминг через `AsyncThrowingStream`.
- [ ] **ТД-8: Тестовый таргет** — добавить в `Package.swift`. Покрыть `FileSystemManager`, `MemoryManager`, `AIOrchestrator`.
- [ ] **ТД-6: Типизация ToolCall** — вызовы инструментов передаются в UI как `String` с эмодзи-префиксом. Нужен отдельный тип.
- [ ] **Обновление `project_map.md` при изменениях** — вызывать `refreshProjectMap()` после рефакторинга.

---

## 📚 Changelog

| Date | Change | Author |
|------|--------|--------|
| 2026-05-21 | Initial creation | Chappie AI |
| 2026-05-27 | Полная переработка: синхронизация с реальным кодом. Исправлены типы (struct/class вместо actor), убраны саб-агенты и delegate_task, добавлены реальные параметры AppConfig, детальное описание всех методов и типов | Chappie AI |
