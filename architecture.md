<!--
  architecture.md (корень проекта)

  ДОКУМЕНТ АРХИТЕКТУРЫ — ПРОЕКТ CHAPPIE (КОРНЕВОЙ УРОВЕНЬ)

  Этот файл — единственный источник архитектурной документации для корня проекта.
  Папки AI_Docs/ в корне и таргетах УПРАЗДНЕНЫ (рефакторинг TD-03).
  
  Обновляй при изменении общей структуры проекта.
-->

# Chappie — Общая архитектура проекта

## 1. Структура проекта

```
/Volumes/Хранилище/Работа/Chappie/
├── architecture.md                     # Этот файл (корневая архитектура)
├── chat_history.json                   # История чата (корень проекта, УСТАРЕВАЕТ — IT-04)
├── ChappieCoreTests.xctestplan         # Тестплан для Xcode
├── Chappie.xcodeproj/                  # Основной Xcode проект
│
├── Chappie/                            # UI-таргет (SwiftUI App, macOS 26+)
│   ├── architecture.md                 # Архитектура UI-слоя
│   └── ...
│
├── ChappieCore/                        # Библиотека (Swift Package, бизнес-логика)
│   ├── architecture.md                 # Архитектура ядра
│   └── ...
│
├── ChappieCoreTests/                   # Тестовый таргет
│   ├── architecture.md                 # Архитектура тестов
│   └── ...
│
└── ChappieMCP/                         # Хелпер-процесс (git + xcodebuild)
    ├── architecture.md                 # Архитектура MCP хелпера
    └── ...
```

---

## 2. Таргеты и их роли

| Таргет | Тип | Назначение |
|---|---|---|
| `Chappie` | SwiftUI App | UI-оболочка, @MainActor, @Observable ViewModel |
| `ChappieCore` | Swift Package Library | Вся бизнес-логика: AI, инструменты, память |
| `ChappieCoreTests` | Unit Test Bundle | Тесты для ChappieCore |
| `ChappieMCP` | Command Line Tool | Дочерний процесс: git + xcodebuild |

---

## 3. Зависимости между таргетами

```
Chappie.app
    ├── depends on → ChappieCore (Swift Package)
    └── embeds → ChappieMCP (Contents/Helpers/)

ChappieCoreTests
    └── depends on → ChappieCore

ChappieMCP
    └── standalone (нет зависимостей от ChappieCore)
```

---

## 4. Ключевые технологии

| Технология | Версия/Тип | Применение |
|---|---|---|
| Swift | 6 (Full Concurrency) | Весь проект |
| SwiftUI | macOS 26+ | UI-слой |
| SwiftData | macOS 26+ | Персистентность тредов, проектов, памяти |
| @Observable | Observation framework | ViewModel |
| Actors | Swift Concurrency | ChappieCore сервисы |
| Claude Sonnet 4.6 | claude-sonnet-4.6 | AI модель |
| AITunnel API | OpenAI-совместимый | Прокси к Anthropic |
| Unix Domain Sockets | POSIX | IPC с ChappieMCP |
| Keychain | Security framework | Хранение API-ключа |

---

## 5. История чата (TD-03) — УСТАРЕВАЕТ

**ВНИМАНИЕ:** `chat_history.json` и `semantic.json` заменены SwiftData в IT-04.
Файлы остаются как backup, но основным хранилищем теперь является SwiftData.

**Миграция выполняется ОДИН РАЗ** при первом запуске новой версии через `MigrationService`.
Флаг `UserDefaults["migration_v1_done"]` предотвращает повторную миграцию.

**Путь:** `<workspaceURL>/chat_history.json` (прямо в корне проекта)

Управляется `ChatHistoryManager` в ChappieCore — продолжает работать параллельно
до полного перехода на SwiftData в IT-05.

---

## 6. Структура памяти (TD-03) — ОБНОВЛЕНО IT-08

Три уровня памяти:

| Уровень | Хранилище | Управляется |
|---|---|---|
| Глобальная (кросс-проектная) | SwiftData MemoryEntity scope="global" | MemoryStore + MemoryManager |
| Проектная | SwiftData MemoryEntity scope="<projectId>" | MemoryStore |
| Тредовая | SwiftData MemoryEntity scope="<threadId>" | MemoryStore |
| Документация таргетов | `<target>/architecture.md` | Чаппи вручную через write_file |

**АВТОМАТИЧЕСКОЕ ПОДМЕШИВАНИЕ В SYSTEM PROMPT (IT-03, обновлено IT-08):**
`MemoryManager.buildSystemPrompt(basePrompt:threadId:projectIds:)` собирает полный промпт:
1. Базовый промпт (захардкоженные правила Чаппи)
2. Глобальная память (scope="global") — из SwiftData
3. Проектная память (scope="<projectId>") — для каждого проекта в треде
4. Тредовая память (scope="<threadId>") — контекст текущей задачи

**МИГРАЦИЯ (IT-04 ✅):**
- `MigrationService.migrate()` — идемпотентный, флаг `UserDefaults["migration_v1_done"]`
- chat_history.json → ThreadEntity "Основной" в SwiftData
- semantic.json → MemoryEntity scope="global" в SwiftData
- Старые файлы НЕ удаляются (backup)

---

## 7. Группа 📚 Docs в Xcode Navigator

**Проблема:** Файлы `architecture.md` лежат в корнях таргетов — Xcode их не показывает в Navigator автоматически.

**Решение:** Группа `📚 Docs` добавлена в `project.pbxproj` как чисто навигационная PBXGroup.
- UUID корневой группы: `87DOCS0000000000000000000`
- Файлы: 5 PBXFileReference с UUID `87DOCS000000000000000000[1-5]`
- **НЕ участвует в сборке**, **НЕ копируется в бандл**

**УПРАВЛЕНИЕ ГРУППОЙ — ТОЛЬКО ВРУЧНУЮ:**
`XcodeDocsGroupManager.swift` был УДАЛЁН (2025-07-10).
Причина: автоматическая запись `project.pbxproj` при каждом запуске приложения
повреждала файл проекта и вызывала `"Failed to load container for document at url: ..."` в Xcode.
Текстовая манипуляция pbxproj слишком хрупка для автоматизации.

**ПРАВИЛО:** При добавлении нового таргета — Чаппи ВРУЧНУЮ обновляет `project.pbxproj`
через `write_file`, добавляя:
1. Новую строку `PBXFileReference` в секцию `/* Begin PBXFileReference section */`
2. Новую строку в `children = (` группы `87DOCS0000000000000000000`

---

## 8. Зависания build_project и run_tests — КОРНЕВАЯ ПРИЧИНА И РЕШЕНИЕ

### Причина 1: Дедлок Pipe (ИСПРАВЛЕНО 2025-07-11)

**Симптом:** `build_project` и `run_tests` зависали навсегда.

**Корневая причина — дедлок Pipe:**
```
process.waitUntilExit()          ← ждёт завершения процесса
// ... после этого ...
pipe.readDataToEndOfFile()       ← читаем вывод
```
Pipe имеет буфер ~64KB. xcodebuild пишет МНОГО вывода (1000+ строк).
Когда буфер заполняется — xcodebuild блокируется в ожидании чтения.
Но мы читаем ПОСЛЕ waitUntilExit(). **Взаимная блокировка навсегда.**

**Решение:** читать stdout/stderr в отдельных DispatchQueue **параллельно** с waitUntilExit():
```swift
readGroup.enter()
DispatchQueue.global(qos: .utility).async {
    stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    readGroup.leave()
}
try process.run()
process.waitUntilExit()
readGroup.wait()
```

### Причина 2: Нет явного destination (ИСПРАВЛЕНО 2025-07-11)

Без явного `arch` xcodebuild на macOS 26 beta зависал, выбирая между устройствами.
**Решение:** добавлен явный `-destination "platform=macOS,arch=arm64"` для обеих команд.

### Причина 3: Таймаут как последняя линия защиты

Таймаут 300с остаётся как страховка от зависания.

---

## 9. Техдолг

| ID | Проблема | Приоритет |
|----|----------|-----------|
| TD-01 | `build_project` зависал — РЕШЕНО (2025-07-11) | ✅ |
| TD-02 | Тесты `ChappieCoreTests` требуют ручного выбора таргета в Xcode перед ⌘+U. | Низкий |

---

## 10. REFACTOR-THREADS — Большой рефакторинг: треды, проекты, SwiftData

### Статус: ✅ ЗАВЕРШЁН (IT-01 ✅, IT-02 ✅, IT-03 ✅, IT-04 ✅, IT-05 ✅, IT-06 ✅, IT-07 ✅)

### Ключевые архитектурные решения

**Принцип JSON-сериализации в SwiftData:**
Вместо того чтобы хранить Swift-модели напрямую в SwiftData (проблемы миграции схемы),
мы храним только примитивы и `Data`. Все сложные объекты сериализуются через JSONEncoder
и хранятся как `Data`. При чтении — JSONDecoder. Это даёт нам свободу эволюции моделей
без болезненных SwiftData-миграций.

**Три уровня памяти в system prompt (IT-03 ✅):**
1. Глобальная память — факты о пользователе, стиль общения, кросс-проектные знания
2. Проектная память — архитектура конкретного проекта, пайплайны, договорённости
3. Тредовая память — контекст текущей задачи, временные заметки

**Инструменты управления проектами — паттерн Callback/Closure (IT-07 ✅):**
ToolExecutionService живёт в ChappieCore, ProjectStore/ThreadStore — тоже в ChappieCore,
но управляются из Chappie.app. Прямая ссылка создала бы проблемы с зависимостями.
Решение: ViewModel регистрирует @Sendable замыкания в ToolExecutionService через
`registerProjectHandlers()`. Замыкания вызываются когда Чаппи использует инструменты.

---

## 11. IT-08 — Переработка инструментов памяти (В ПЛАНЕ)

### Контекст и мотивация

Текущие инструменты `memorize/recall/search_memory/delete_memory` пишут в **legacy-файл**
`~/Documents/Chappie/semantic.json` — они не используют SwiftData MemoryStore.
Это разрыв: buildSystemPrompt() читает из SwiftData, а инструменты пишут в файл.

Цель IT-08 — замкнуть петлю: инструменты памяти должны писать в SwiftData MemoryStore
с умным маппингом scope через контекст активного треда/проектов.

### Ключевые архитектурные решения IT-08

**Модель связей — многие-ко-многим без владения:**
```
Тред ←→ Проект  (связь, не владение)
Global ←→ всё   (кросс-проектные знания)
```
Тред не владеет проектами. Проекты не владеют тредами.
Один проект может быть в нескольких тредах — у него свои правила/пайплайны.
Один тред может вести несколько проектов параллельно.

**Новый API scope инструментов:**

| Параметр | Значение | Что происходит |
|---|---|---|
| `scope = "global"` | (нет targetName) | Пишет в scope="global" |
| `scope = "thread"` | (нет targetName) | Пишет в scope=UUID активного треда |
| (нет scope) + `targetName = "Chappie"` | имя проекта | Ищет проект по имени среди прикреплённых к треду → пишет в scope=UUID проекта |

**УБИРАЕМ scope="project" как неоднозначный:**
В треде может быть несколько проектов. "project" без имени — непонятно какой.
Для проектной памяти ОБЯЗАТЕЛЕН явный `targetName`.
Если targetName не указан при записи в проект — ошибка с подсказкой.

**Контекст памяти в ToolExecutionService:**
ToolExecutionService уже хранит `activeProjectNames: [String]` для PROJECT GUARD.
Нужно расширить до `activeMemoryContext: MemoryContext` — тогда инструменты будут
знать UUID треда и UUID каждого проекта для корректного маппинга scope.

**Разрешение конфликтов:**
Если инструкции в разных уровнях памяти противоречат друг другу —
Чаппи ОСТАНАВЛИВАЕТСЯ, объясняет конфликт пользователю и ждёт решения.
Это правило добавляется хардкодом в baseSystemPrompt оркестратора.

### Что меняется в коде (IT-08)

**1. ToolExecutionService.swift**
- Заменить `activeProjectNames: [String]` на `activeMemoryContext: ActiveMemoryContext`
  (новая структура: threadId + [(projectId, projectName)])
- Добавить метод `setActiveMemoryContext(_ context: ActiveMemoryContext)`
  (заменяет `setActiveProjectNames()`)
- Инструменты `memorize/recall/search_memory/delete_memory` — переписать:
  теперь они вызывают MemoryStore напрямую через новый обработчик
- Добавить `memoryHandler: @Sendable (MemoryOperation) async -> String`
  (аналог projectHandler — ViewModel регистрирует его когда MemoryStore готов)

**2. MemoryStore.swift**
- Добавить метод `searchEntries(type:scopes:)` — поиск по нескольким scope сразу
  (нужен для search_memory когда нет явного targetName)

**3. MemoryManager.swift**
- Убрать legacy-блок из `buildSystemPrompt()` — теперь только SwiftData
  (legacy semantic.json уже мигрирован в IT-04)
- Убрать методы `saveMemory/readMemory/searchMemory/deleteMemory` (legacy)
  или оставить как deprecated с предупреждением

**4. AIOrchestrator.swift (baseSystemPrompt)**
- Добавить правило 9: CONFLICT RESOLUTION
  "If instructions in different memory levels (global/project/thread) contradict each other —
   STOP, explain the conflict to the user, wait for resolution before proceeding."
- Обновить правило 4 (MEMORY STRUCTURE) — новый API scope

**5. ChappieViewModel.swift**
- `setActiveProjectNames()` → `setActiveMemoryContext()` с полными UUID
- Зарегистрировать `memoryHandler` аналогично `projectHandler`

### Новая структура ActiveMemoryContext

```swift
/// Контекст активного треда для инструментов памяти.
/// Хранится в ToolExecutionService, обновляется при смене треда/проектов.
public struct ActiveMemoryContext: Sendable {
    /// UUID активного треда.
    let threadId: UUID?
    
    /// Список проектов треда: (UUID, displayName).
    /// UUID нужен для scope памяти, displayName — для маппинга по targetName.
    let projects: [(id: UUID, name: String)]
    
    static let empty = ActiveMemoryContext(threadId: nil, projects: [])
}
```

### Маппинг scope при вызове memorize

```
memorize(key, type, json, scope="global")
    → MemoryStore.saveEntry(scope: "global")

memorize(key, type, json, scope="thread")
    → MemoryStore.saveEntry(scope: activeMemoryContext.threadId.uuidString)
    → Ошибка если threadId == nil

memorize(key, type, json, targetName="Chappie")
    → Найти проект с name=="Chappie" в activeMemoryContext.projects
    → MemoryStore.saveEntry(scope: project.id.uuidString)
    → Ошибка если проект не найден среди прикреплённых к треду
```

### Итерации IT-08

| # | Шаг | Описание |
|---|---|---|
| IT-08-1 | ActiveMemoryContext | Заменить activeProjectNames на ActiveMemoryContext в ToolExecutionService |
| IT-08-2 | MemoryHandler | Добавить memoryHandler в ToolExecutionService + регистрация в ViewModel |
| IT-08-3 | Инструменты памяти | Переписать memorize/recall/search_memory/delete_memory через MemoryStore |
| IT-08-4 | Промпт | Обновить baseSystemPrompt: правило конфликтов + новый API scope |
| IT-08-5 | Очистка | Убрать legacy-блок из buildSystemPrompt(), deprecate saveMemory/readMemory |

---

## 12. REFACTOR-THREADS — Пошаговый план итераций

### ✅ / 🔲 Статус итераций

| # | Итерация | Статус |
|---|---|---|
| IT-01 | SwiftData модели + JSON-сериализация | ✅ ГОТОВО |
| IT-02 | ThreadSettings + динамический AppConfig | ✅ ГОТОВО |
| IT-03 | Трёхуровневая память в system prompt | ✅ ГОТОВО |
| IT-04 | Миграция старых файлов → SwiftData | ✅ ГОТОВО |
| IT-05 | UI: боковая панель тредов | ✅ ГОТОВО |
| IT-06 | UI: плашки проектов в треде | ✅ ГОТОВО |
| IT-07 | Инструменты add/remove project | ✅ ГОТОВО |
| IT-08 | Переработка инструментов памяти (SwiftData + умный scope) | 🔲 В ПЛАНЕ |

---

## 13. История чата (TD-03)

**Путь:** `<workspaceURL>/chat_history.json` (прямо в корне проекта)

Управляется `ChatHistoryManager` в ChappieCore.

**Ключевые решения:**
- Файл лежит в КОРНЕ воркспейса (не в AI_Docs/ — папка упразднена).
- Автоматическое подрезание до 100 сообщений при каждом сохранении.
- После IT-05 — история хранится в ThreadStore (SwiftData), ChatHistoryManager устаревает.

---

## 📚 Changelog

| Date | Change |
|------|--------|
| 2025-07-XX | IT-08 ЗАПЛАНИРОВАН: переработка инструментов памяти, ActiveMemoryContext, умный scope-маппинг |
| 2025-07-XX | IT-07 ГОТОВО: add/remove/list_thread_projects инструменты, registerProjectHandlers() в ToolExecutionService |
| 2025-07-XX | IT-06 ГОТОВО: ProjectChipsView, ChappieViewModel addProject/removeProject |
| 2025-07-XX | IT-05 ГОТОВО: ThreadListView, ThreadRowView, SidebarView с тредами |
| 2025-07-XX | IT-04 ГОТОВО: MigrationService (chat_history.json + semantic.json → SwiftData) |
| 2025-07-XX | IT-03 ГОТОВО: MemoryStore (SwiftData CRUD), buildSystemPrompt() с трёхуровневой памятью |
| 2025-07-XX | IT-02 ГОТОВО: динамический AppConfig, tokenBudget = maxMessages × 500 |
| 2025-07-XX | IT-01 ГОТОВО: SwiftData модели (ThreadEntity, ProjectEntity, MemoryEntity) |
| 2025-07-11 | РЕШЕНО TD-01: исправлен дедлок Pipe в BuildTools.swift |
| 2025-07-10 | КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: удалён XcodeDocsGroupManager |
