<!--
  ChappieCore/architecture.md

  ЕДИНЫЙ ДОКУМЕНТ АРХИТЕКТУРЫ — CHAPPIECORE (БИЗНЕС-ЛОГИКА)

  Этот файл — единственный источник архитектурной документации для ChappieCore.
  Обновляй при каждом значимом архитектурном изменении.
-->

# ChappieCore — Архитектура библиотеки

## 1. Назначение

**ChappieCore** — Swift Package Library, содержащая всю бизнес-логику Чаппи.
UI-таргет `Chappie.app` — тонкая оболочка, ChappieCore делает всю реальную работу.

### Принцип изоляции

- **Никакого UIKit/SwiftUI** в ChappieCore — только Foundation и системные фреймворки.
- **Все сервисы — акторы** (`actor`) для безопасного конкурентного доступа в Swift 6.
- **Публичный API** — только то, что нужно UI-таргету. Детали реализации — `internal`.

---

## 2. Структура файлов

```
ChappieCore/Sources/ChappieCore/
├── ChappieCore.swift                   # Публичный фасад библиотеки
├── Models/
│   ├── AITunnelModels.swift            # AIMessage, AIToolCall, AIStreamResult и т.д.
│   ├── AppConfig.swift                 # Конфигурация: токены, лимиты, модель
│   ├── ChappieError.swift              # Типизированные ошибки
│   ├── ThreadModels.swift              # [IT-01] ThreadEntity, ThreadSettings, ProjectBinding
│   ├── ProjectModels.swift             # [IT-01] ProjectEntity, ProjectSettings
│   └── MemoryModels.swift              # [IT-01] MemoryEntity, MemoryEntry
└── Services/
    ├── AIOrchestrator.swift            # Агентный цикл: запрос → инструменты → ответ
    ├── AITunnelClient.swift            # HTTP-клиент к AITunnel API (стриминг SSE)
    ├── ChatHistoryManager.swift        # [УСТАРЕВАЕТ] Сохранение/загрузка истории чата
    ├── FileSystemManager.swift         # Чтение/запись файлов (с защитой Path Traversal)
    ├── MCPToolBridge.swift             # Unix Domain Socket клиент к ChappieMCP
    ├── MemoryManager.swift             # Семантическая память + инициализация воркспейса
    ├── MemoryStore.swift               # [IT-01] SwiftData CRUD для трёхуровневой памяти
    ├── ToolExecutionService.swift      # Диспетчер вызовов инструментов от модели
    ├── ThreadStore.swift               # [IT-01] CRUD операции над тредами через SwiftData
    ├── ProjectStore.swift              # [IT-01] CRUD операции над проектами через SwiftData
    └── MigrationService.swift          # [IT-04] Миграция chat_history.json → SwiftData
```

---

## 3. Ключевые сервисы

### AIOrchestrator
Главный управляющий компонент. Реализует агентный цикл:
`запрос → streamRequestWithTools → tool_calls? → выполнить → повторить → финальный ответ`

**Ключевые решения:**
- Единый стриминговый цикл (не два запроса probe+stream)
- Умное контекстное окно: tokenBudget + maxMessagesInContext
- Сжатие старых сообщений через `<summary>` тег
- Защита от зацикливания: подряд-блокировка (lastToolSignature)
- **[IT-02]** Принимает `config: AppConfig` как параметр (с дефолтом `AppConfig.shared`)
- **[IT-03]** Принимает `memoryContext: MemoryContext` для трёхуровневой памяти

### MemoryManager
Управляет файловой структурой памяти воркспейса.

**[IT-03] Методы:**
- `buildSystemPrompt(basePrompt:threadId:projectIds:)` — собирает полный трёхуровневый system prompt
- `setMemoryStore(_:)` — подключает SwiftData бэкенд (вызывается из ViewModel)

**[УСТАРЕВАЕТ после IT-08]:**
- `saveMemory/readMemory/searchMemory/deleteMemory` — legacy методы, пишут в файл

### MemoryStore [IT-01]
Actor. CRUD операции над памятью через SwiftData.
- `saveEntry(key:type:jsonString:scope:)` — UPSERT запись
- `readEntry(key:scope:)` — читает одну запись
- `readAllEntries(scope:)` — все записи scope
- `searchEntries(type:scope:)` — поиск по типу в одном scope
- `readEntriesForScopes(_:)` — массовая загрузка для buildSystemPrompt()
- `deleteEntry(key:scope:)` — удалить запись
- `deleteScope(_:)` — удалить весь scope (при удалении треда/проекта)
- `importEntries(_:intoScope:)` — массовый импорт (MigrationService)

### FileSystemManager
"Руки" ИИ-агента в файловой системе. Защита от Path Traversal (CWE-22).

### MCPToolBridge
Unix Domain Socket клиент. Отправляет JSON-запросы к `ChappieMCP` хелперу.
Сокет: `/tmp/com.chappie.mcp.sock`

### ThreadStore [IT-01]
Actor. CRUD операции над тредами через SwiftData.

### ProjectStore [IT-01]
Actor. CRUD операции над проектами через SwiftData.

### MigrationService [IT-04]
Идемпотентный сервис миграции. Проверяет `UserDefaults["migration_v1_done"]`.

---

## 4. Трёхуровневая память (IT-03, IT-08)

### Уровни и scope

| Уровень | scope в SwiftData | Кто пишет | Кто читает |
|---------|-------------------|-----------|------------|
| Глобальная | `"global"` | memorize(scope="global") | buildSystemPrompt() |
| Проектная | `"<projectId UUID>"` | memorize(targetName="Chappie") | buildSystemPrompt() |
| Тредовая | `"<threadId UUID>"` | memorize(scope="thread") | buildSystemPrompt() |

### Модель связей (IT-08)

```
Тред ←→ Проект  (многие-ко-многим, без владения)
Global ←→ всё   (кросс-проектные знания)
```

Тред НЕ владеет проектами. Проекты НЕ владеют тредами.
Один проект может быть в нескольких тредах.
Один тред может вести несколько проектов параллельно.

### Инструменты памяти — новый API (IT-08)

**memorize:**
```
scope="global"                → MemoryStore.saveEntry(scope: "global")
scope="thread"                → MemoryStore.saveEntry(scope: threadId.uuidString)
targetName="Chappie"          → найти проект по имени → saveEntry(scope: projectId.uuidString)
```

**Обязательные правила:**
- `scope="project"` — УБРАН (неоднозначен при нескольких проектах в треде)
- Для проектной памяти ОБЯЗАТЕЛЕН явный `targetName`
- Если targetName не найден среди проектов треда — ошибка с подсказкой

### Разрешение конфликтов памяти (IT-08)

Если инструкции в разных уровнях памяти (global/project/thread) противоречат друг другу —
Чаппи ОСТАНАВЛИВАЕТСЯ, объясняет конфликт пользователю и ждёт решения.
Правило захардкожено в baseSystemPrompt оркестратора.

---

## 5. IT-08 — Переработка инструментов памяти (В ПЛАНЕ)

### Что меняется

**ToolExecutionService.swift:**
- Заменить `activeProjectNames: [String]` на `activeMemoryContext: ActiveMemoryContext`
- Метод `setActiveProjectNames()` → `setActiveMemoryContext()`
- Инструменты памяти переписать: вызывают MemoryStore через `memoryHandler`
- Добавить `memoryHandler: @Sendable (MemoryOperation) async -> String`

**MemoryStore.swift:**
- Добавить `searchEntries(type:scopes:)` — поиск по нескольким scope одновременно

**MemoryManager.swift:**
- Убрать legacy-блок из `buildSystemPrompt()` (только SwiftData)
- Deprecate `saveMemory/readMemory/searchMemory/deleteMemory`

**AIOrchestrator.swift (baseSystemPrompt):**
- Добавить правило CONFLICT RESOLUTION
- Обновить правило MEMORY STRUCTURE — новый API scope

**ChappieViewModel.swift:**
- `setActiveProjectNames()` → `setActiveMemoryContext()` с полными UUID
- Зарегистрировать `memoryHandler`

### ActiveMemoryContext (новая структура)

```swift
/// Контекст активного треда для инструментов памяти.
/// Хранится в ToolExecutionService, обновляется при смене треда/проектов.
public struct ActiveMemoryContext: Sendable {
    let threadId: UUID?
    let projects: [(id: UUID, name: String)]  // UUID для scope, name для маппинга
    static let empty = ActiveMemoryContext(threadId: nil, projects: [])
}
```

### Итерации IT-08

| # | Шаг | Описание |
|---|---|---|
| IT-08-1 | ActiveMemoryContext | Заменить activeProjectNames → ActiveMemoryContext |
| IT-08-2 | MemoryHandler | Добавить memoryHandler в ToolExecutionService + ViewModel |
| IT-08-3 | Инструменты памяти | Переписать memorize/recall/search/delete через MemoryStore |
| IT-08-4 | Промпт | Обновить baseSystemPrompt: конфликты + новый API scope |
| IT-08-5 | Очистка | Убрать legacy из buildSystemPrompt(), deprecate старые методы |

---

## 6. Агентный цикл (детали)

```
process(prompt:history:config:memoryContext:onToolCall:onToken:)
    ↓
buildSystemPrompt()           ← MemoryManager: base + global + project + thread
    ↓
buildContextWindow()          ← дедупликация + tokenBudget + maxMessages
    ↓
while stepCount < maxSteps:
    streamRequestWithTools()  ← ОДИН запрос, стриминг SSE
        ↓ onToken             ← каждый токен → UI
    if toolCalls:
        executeToolCalls()    ← ToolExecutionService.execute()
        continue
    else:
        return finalResponse  ← текст уже в UI через onToken
```

---

## 7. Контекстное окно (AppConfig параметры)

| Параметр | Источник | Диапазон |
|----------|----------|----------|
| `maxMessagesInContext` | `ThreadSettings.maxMessagesInContext` | 10...100 |
| `tokenBudget` | Вычисляется: `maxMessagesInContext × 500` | 5,000...50,000 |
| `recentFullMessages` | Захардкожен (3) | — |
| `summaryThreshold` | Захардкожен (400) | — |
| `maxOrchestratorSteps` | Захардкожен (20) | — |

**Дефолт:** `AppConfig.shared` — 20 сообщений, 10,000 токенов.

---

## 8. SwiftData схема

```swift
ThreadEntity (SwiftData)
├── id: UUID
├── title: String
├── createdAt: Date
├── updatedAt: Date
├── messagesJSON: Data          ← [ChatMessage] через JSONEncoder
├── settingsJSON: Data          ← ThreadSettings через JSONEncoder
└── projectBindingsJSON: Data   ← [UUID] — список ID проектов в треде

ProjectEntity (SwiftData)
├── id: UUID
├── displayName: String
├── bookmarkData: Data          ← security-scoped bookmark
├── createdAt: Date
└── settingsJSON: Data          ← ProjectSettings через JSONEncoder

MemoryEntity (SwiftData)
├── id: UUID
├── scope: String               ← "global" | "<projectId>" | "<threadId>"
└── entriesJSON: Data           ← [MemoryEntry] через JSONEncoder
```

**Принцип JSON-сериализации:**
Только примитивы и Data в SwiftData. Все сложные объекты через JSONEncoder/JSONDecoder.
Свобода эволюции моделей без болезненных SwiftData-миграций.

---

## 9. Кэширование промптов

**TOP-LEVEL cache_control** — единственный правильный способ:
```json
{
  "cache_control": { "type": "ephemeral", "ttl": "1h" },
  "messages": [...]
}
```

**ЗАПРЕЩЕНО:** per-block cache_control внутри content (ломает парсинг шлюза).

TTL варианты Anthropic: **5 минут** и **1 час** (других нет).
TTL 1h оптимален для разработки — сессии короче часа.

---

## 10. Технический долг

| # | Описание | Приоритет | Статус |
|---|----------|-----------|--------|
| IT-08 | Переработка инструментов памяти (SwiftData + умный scope) | 🔴 | 🔲 В плане |
| ТД-TEST | Unit-тесты для XcodeDocsGroupManager | 🟡 | 🔲 Открыт |

---

## 📚 Changelog

| Date | Change |
|------|--------|
| 2025-07-XX | IT-08 ЗАПЛАНИРОВАН: ActiveMemoryContext, memoryHandler, умный scope-маппинг, конфликт-резолюция |
| 2025-07-XX | REFACTOR-THREADS IT-01..IT-07 завершён |
| 2025-07-XX | TOP-LEVEL-CACHE: добавлено поле cache_control в AITunnelRequest, TTL 1h |
| 2025-07-XX | ИНЦИДЕНТ: Gemini убрал кэширование при фиксе cancelled. Восстановлено через top-level cache_control |
| 2026-06-XX | Рефакторинг: AI_Docs/ → один файл architecture.md |
| 2026-05-21 | Initial creation |
