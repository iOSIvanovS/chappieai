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
│   ├── ProjectModels.swift             # [IT-01, IT-09] ProjectEntity, ProjectSettings + enums
│   └── MemoryModels.swift              # [IT-01] MemoryEntity, MemoryEntry, ActiveMemoryContext
└── Services/
    ├── AIOrchestrator.swift            # Агентный цикл + MemoryContext с настройками проектов
    ├── AITunnelClient.swift            # HTTP-клиент к AITunnel API (стриминг SSE)
    ├── ChatHistoryManager.swift        # [УСТАРЕВАЕТ] Сохранение/загрузка истории чата
    ├── FileSystemManager.swift         # Чтение/запись файлов (с защитой Path Traversal)
    ├── MCPToolBridge.swift             # Unix Domain Socket клиент к ChappieMCP
    ├── MemoryManager.swift             # Семантическая память + buildSystemPrompt с Settings
    ├── MemoryStore.swift               # [IT-01] SwiftData CRUD для трёхуровневой памяти
    ├── ToolExecutionService.swift      # Диспетчер вызовов + проверка прав (IT-09)
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
- **[IT-02]** Принимает `config: AppConfig` как параметр
- **[IT-03]** Принимает `memoryContext: MemoryContext` для трёхуровневой памяти
- **[IT-08]** `MemoryContext.projectInfos: [ProjectInfo(id, name)]`
- **[IT-09]** `MemoryContext.ProjectInfo` расширен полем `settings: ProjectSettings?`

### MemoryManager
Управляет файловой структурой памяти воркспейса.

**[IT-09] buildSystemPrompt() — структура промпта:**
```
[базовый промпт]

---
## Memory Context

## Project Settings: Chappie          ← IT-09: права агента (ПЕРВЫМ!)
- Role: EXECUTOR
- Git: write [git_status, git_add, ...]
...

## Global Memory                       ← глобальная память
## Project Memory: Chappie             ← проектная память
## Thread Context                      ← тредовая память
```

**Порядок блоков:** Settings → Global → Project Memory → Thread
**Почему Settings первым:** агент должен знать ограничения ДО работы с памятью.

### ToolExecutionService [IT-09]
Диспетчер инструментов с проверкой прав.

**Порядок проверок в execute():**
1. **PROJECT GUARD** — файловые/git/build инструменты требуют проекта в треде
2. **TOOL ACCESS CHECK** — `checkToolAccess()` проверяет ProjectSettings
3. Выполнение инструмента

**checkToolAccess() логика:**
- `git_diff` → всегда FORBIDDEN (железный запрет)
- Роль `.advisor` → только `list_files, read_file, read_build_log`
- Git инструменты → проверяем `GitAccessLevel.allowedTools`
- Build/tests → проверяем `TestsAccessLevel.canRun`

**setProjectSettings([UUID: ProjectSettings])** — кэш настроек проектов.
Вызывается из `ChappieViewModel.syncActiveMemoryContext()`.
Настройки берутся из первого проекта в треде (MVP-упрощение).

---

## 4. IT-09: ProjectSettings — права агента

### Модели

```swift
AgentRole: .advisor | .executor
GitAccessLevel: .none | .statusOnly | .write | .full
TestsAccessLevel: .none | .readOnly | .run | .write
ProjectLanguage: .english | .native
```

### ProjectSettings поля

```swift
// Основные (всегда)
agentRole: AgentRole = .advisor      // БЕЗОПАСНЫЙ ДЕФОЛТ
preferredLanguage: String?

// Тип проекта
isProgrammingProject: Bool = false   // Разблокирует расширенные настройки

// Расширенные (только isProgrammingProject = true)
gitAccess: GitAccessLevel = .none
testsAccess: TestsAccessLevel = .none
architectureEnabled: Bool = false
architectureLanguage: ProjectLanguage = .english
commentsEnabled: Bool = false
commentsLanguage: ProjectLanguage = .english
```

### Правила

- `git_diff` НИКОГДА не разрешён ни на каком уровне GitAccessLevel
- При смене executor → advisor: `downgradeToAdvisor()` сбрасывает ВСЕ флаги
- Настройки хранятся в `ProjectEntity.settingsJSON` (SwiftData)
- `formatForSystemPrompt(projectName:)` → блок прав для промпта

---

## 5. Трёхуровневая память (IT-03, IT-08 ✅)

### Уровни и scope

| Уровень | scope в SwiftData | Инструмент |
|---------|-------------------|------------|
| Глобальная | `"global"` | memorize(scope="global") |
| Проектная | `"<projectId UUID>"` | memorize(targetName="Chappie") |
| Тредовая | `"<threadId UUID>"` | memorize(scope="thread") |

### Инструменты памяти — финальный API (IT-08 ✅)

- `scope="global"` → MemoryStore.saveEntry(scope: "global")
- `scope="thread"` → MemoryStore.saveEntry(scope: threadId.uuidString)
- `targetName="Chappie"` → найти проект по имени → saveEntry(scope: projectId.uuidString)

**Обязательные правила:**
- `scope="project"` — УБРАН (неоднозначен при нескольких проектах)
- Для проектной памяти ОБЯЗАТЕЛЕН явный `targetName`
- Если targetName не найден — ошибка с подсказкой

---

## 6. Агентный цикл (детали)

```
process(prompt:history:config:memoryContext:onToolCall:onToken:)
    ↓
buildSystemPrompt(basePrompt:memoryContext:)
    → Settings blocks (IT-09)
    → Global Memory
    → Project Memory blocks
    → Thread Context
    ↓
buildContextWindow()
    ↓
while stepCount < maxSteps:
    streamRequestWithTools()
        ↓ onToken → UI
    if toolCalls:
        executeToolCalls()
            → checkToolAccess() (IT-09)
            → ToolExecutionService.execute()
        continue
    else:
        return finalResponse
```

---

## 7. SwiftData схема

```swift
ThreadEntity
├── id: UUID
├── title: String
├── createdAt/updatedAt: Date
├── messagesJSON: Data          ← [ChatMessage]
├── settingsJSON: Data          ← ThreadSettings
└── projectBindingsJSON: Data   ← [UUID]

ProjectEntity
├── id: UUID
├── displayName: String
├── bookmarkData: Data          ← security-scoped bookmark
├── createdAt: Date
└── settingsJSON: Data          ← ProjectSettings (IT-09: расширен)

MemoryEntity
├── id: UUID
├── scope: String               ← "global" | "<projectId>" | "<threadId>"
└── entriesJSON: Data           ← [MemoryEntry]
```

---

## 8. Контекстное окно (AppConfig параметры)

| Параметр | Источник | Диапазон |
|----------|----------|----------|
| `maxMessagesInContext` | `ThreadSettings` | 10...100 |
| `tokenBudget` | `maxMessages × 500` | 5,000...50,000 |
| `recentFullMessages` | Захардкожен (3) | — |
| `summaryThreshold` | Захардкожен (400) | — |
| `maxOrchestratorSteps` | Захардкожен (20) | — |

---

## 9. Кэширование промптов

**TOP-LEVEL cache_control:**
```json
{ "cache_control": { "type": "ephemeral", "ttl": "1h" } }
```
TTL 1h оптимален для разработки. ЗАПРЕЩЕНО: per-block cache_control (ломает шлюз).

---

## 10. Технический долг

| # | Описание | Приоритет | Статус |
|---|----------|-----------|--------|
| ТД-TEST | Unit-тесты для ключевых сервисов | 🟡 | 🔲 Открыт |

---

## 📚 Changelog

| Date | Change |
|------|--------|
| 2026-05-26 | IT-09 ✅: ProjectSettings (AgentRole, GitAccessLevel, TestsAccessLevel, ProjectLanguage), formatForSystemPrompt(), ToolExecutionService.checkToolAccess(), MemoryContext.ProjectInfo.settings |
| 2025-07-XX | IT-08 ✅: UUID-based scope, ActiveMemoryContext, resolveScope(), имена проектов в заголовках |
| 2025-07-XX | REFACTOR-THREADS IT-01..IT-07 завершён |
