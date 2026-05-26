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
- Защита от зацикливания: `executedToolSignatures`
- **[IT-02]** Принимает `config: AppConfig` как параметр (с дефолтом `AppConfig.shared`)

### MemoryManager
Управляет файловой структурой памяти воркспейса.

**Что делает при инициализации:**
1. Создаёт `~/Documents/Chappie/semantic.json` (глобальная память)
2. Сканирует таргеты воркспейса (папки без расширения в корне)
3. Создаёт `architecture.md` для новых таргетов (шаблон)
4. Удаляет устаревшие `AI_Docs/` и `semantic.json` в таргетах (миграция)

**[IT-03] Новые методы:**
- `loadGlobalMemory()` — читает MemoryEntity с scope="global"
- `loadProjectMemory(projectId:)` — читает MemoryEntity для проекта
- `loadThreadMemory(threadId:)` — читает MemoryEntity для треда
- `buildSystemPrompt(threadId:projectIds:)` — собирает полный трёхуровневый system prompt

### FileSystemManager
"Руки" ИИ-агента в файловой системе. Защита от Path Traversal (CWE-22):
`validateAndResolvePath()` → `standardized` + `resolvingSymlinksInPath()` → `hasPrefix(workspacePath)`

### MCPToolBridge
Unix Domain Socket клиент. Отправляет JSON-запросы к `ChappieMCP` хелперу.
Сокет: `/tmp/com.chappie.mcp.sock`

### ThreadStore [IT-01]
Actor. CRUD операции над тредами через SwiftData.
- `createThread(title:)` → `ThreadEntity`
- `loadThreads()` → `[ThreadEntity]` (сортировка по updatedAt)
- `saveMessages(_ messages: [ChatMessage], toThread:)` — сериализует через JSONEncoder
- `loadMessages(fromThread:)` → `[ChatMessage]` — десериализует через JSONDecoder
- `deleteThread(_:)`

### ProjectStore [IT-01]
Actor. CRUD операции над проектами через SwiftData.
- `addProject(displayName:bookmarkData:)` → `ProjectEntity`
- `loadProjects()` → `[ProjectEntity]`
- `deleteProject(_:)`

### MigrationService [IT-04]
Идемпотентный сервис миграции. Проверяет `UserDefaults["migration_v1_done"]`.
- Читает `chat_history.json`, создаёт тред "Основной", переносит историю
- Читает `semantic.json`, переносит в MemoryEntity с scope="global"
- Старые файлы НЕ удаляет — оставляет как backup

---

## 4. Структура памяти

### Текущая (файловая, УСТАРЕВАЕТ):

| Уровень | Файл | Управляется |
|---------|------|-------------|
| Глобальная | `~/Documents/Chappie/semantic.json` | `MemoryManager` |
| Документация таргета | `<Target>/architecture.md` | Чаппи вручную через `write_file` |
| История чата | `<WorkspaceRoot>/chat_history.json` | `ChatHistoryManager` |

### Новая (SwiftData + JSON, REFACTOR-THREADS):

| Уровень | SwiftData Entity | scope |
|---------|-----------------|-------|
| Глобальная | `MemoryEntity` | `"global"` |
| Проектная | `MemoryEntity` | `"<projectId>"` |
| Тредовая | `MemoryEntity` | `"<threadId>"` |
| История треда | `ThreadEntity.messagesJSON` | — |

**Документация таргетов (`architecture.md`) остаётся файловой** — это не память AI,
это документация кода для разработчика и Чаппи как разработчика.

---

## 5. Агентный цикл (детали)

```
process(prompt:history:config:onToolCall:onToken:)
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

## 6. Контекстное окно (AppConfig параметры)

### Текущие (захардкожены):

| Параметр | Значение | Назначение |
|----------|----------|------------|
| `tokenBudget` | 6,000 | Мягкий лимит токенов |
| `maxMessagesInContext` | 12 | Жёсткий лимит сообщений |
| `recentFullMessages` | 3 | Последние N — всегда полностью |
| `summaryThreshold` | 400 | Длиннее → заменить на summary |
| `maxOrchestratorSteps` | 20 | Защита от бесконечного цикла |

### После IT-02 (динамические):

| Параметр | Источник | Диапазон |
|----------|----------|----------|
| `maxMessagesInContext` | `ThreadSettings.maxMessagesInContext` | 10...100 |
| `tokenBudget` | Вычисляется: `maxMessagesInContext × 500` | 5,000...50,000 |
| `recentFullMessages` | Захардкожен (3) | — |
| `summaryThreshold` | Захардкожен (400) | — |
| `maxOrchestratorSteps` | Захардкожен (20) | — |

**Дефолт:** `AppConfig.shared` — 20 сообщений, 10,000 токенов.

**Механизм двойного отсечения (наследуется без изменений):**
1. Жёсткий лимит по количеству (`maxMessagesInContext`) — применяется первым
2. Мягкий лимит по токенам (`tokenBudget`) — применяется вторым
3. Summary-сжатие старых длинных сообщений — под капотом, не меняется

---

## 7. SwiftData модели (IT-01)

### Принцип JSON-сериализации

Вместо хранения Swift-моделей напрямую в SwiftData (проблемы миграции схемы),
мы храним только примитивы и `Data`. Все сложные объекты — через JSONEncoder/JSONDecoder.
Это даёт свободу эволюции моделей без болезненных SwiftData-миграций.

```swift
// ThreadEntity — только примитивы и Data
@Model final class ThreadEntity {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messagesJSON: Data          // [ChatMessage] через JSONEncoder
    var settingsJSON: Data          // ThreadSettings через JSONEncoder
    var projectBindingsJSON: Data   // [UUID] через JSONEncoder
}

// ProjectEntity — только примитивы и Data
@Model final class ProjectEntity {
    var id: UUID
    var displayName: String
    var bookmarkData: Data          // security-scoped bookmark
    var createdAt: Date
    var settingsJSON: Data          // ProjectSettings через JSONEncoder
}

// MemoryEntity — только примитивы и Data
@Model final class MemoryEntity {
    var id: UUID
    var scope: String               // "global" | "<projectId>" | "<threadId>"
    var entriesJSON: Data           // [MemoryEntry] через JSONEncoder
}
```

---

## 8. ⚠️ КРИТИЧЕСКОЕ ПРАВИЛО: формат запросов к AITunnel

### Проблема (зафиксирована после инцидента с Gemini)

**AITunnel — OpenAI-совместимый шлюз**, а НЕ нативный Anthropic API.
Это означает: поле `content` в сообщениях ОБЯЗАНО быть **строкой**, не массивом объектов.

### ❌ ЗАПРЕЩЕНО (ломает шлюз):

```json
{
  "role": "system",
  "content": [
    {
      "type": "text",
      "text": "...",
      "cache_control": {"type": "ephemeral"}
    }
  ]
}
```

Это **Anthropic-нативный формат** с `cache_control`. Когда Cloudflare/nginx на стороне
AITunnel получает массив вместо строки — он давится при парсинге и закрывает QUIC/HTTP3
соединение. Клиент получает `URLError(.cancelled)` → `ChappieError.cancelled`.

### ✅ ПРАВИЛЬНО (OpenAI-совместимый формат):

```json
{
  "role": "system",
  "content": "просто строка с текстом промпта"
}
```

### Правило для `buildMessages()` в `AITunnelClient.swift`:

- `AIMessage.content` — ВСЕГДА `String?`, НИКОГДА не массив content-блоков.
- Кэширование промптов — НЕ через `cache_control` в теле запроса.
  Шлюз AITunnel кэширует на своей стороне автоматически.
- Если захочется добавить prompt caching — сначала проверить документацию AITunnel,
  поддерживает ли шлюз Anthropic-специфичные расширения. Скорее всего — нет.

### Симптомы нарушения этого правила:
- Сообщения вообще не уходят на бэкенд
- `URLError(.cancelled)` сразу при отправке запроса
- Ошибка "Упс, ошибка: cancelled" в UI без видимой причины
- QUIC/HTTP3 соединение закрывается на стороне шлюза

---

## 9. Технический долг

| # | Описание | Приоритет | Статус |
|---|----------|-----------|--------|
| ТД-TEST | Unit-тесты для XcodeDocsGroupManager | 🟡 | 🔲 Открыт |
| REFACTOR-THREADS | Мультитредовость + SwiftData | 🔴 | ✅ IT-01..IT-07 завершён |

---

## 📚 Changelog

| Date | Change |
|------|--------|
| 2026-05-21 | Initial creation |
| 2026-06-XX | Рефакторинг: AI_Docs/ → один файл architecture.md |
| 2026-06-XX | XcodeDocsGroupManager: автосинхронизация группы 📚 Docs в pbxproj |
| 2025-07-XX | REFACTOR-THREADS: зафиксирована полная архитектура SwiftData + JSON-сериализация |
| 2025-07-XX | REFACTOR-THREADS: динамический AppConfig (tokenBudget = maxMessages × 500) |
| 2025-07-XX | REFACTOR-THREADS: трёхуровневая память (global + project + thread) |
| 2025-07-XX | ИНЦИДЕНТ: зафиксировано критическое правило формата AITunnel (раздел 8) |
