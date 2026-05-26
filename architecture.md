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

## 6. Структура памяти — ФИНАЛЬНАЯ (IT-08 ✅)

Три уровня памяти, все в SwiftData:

| Уровень | Хранилище | Инструмент |
|---|---|---|
| Глобальная | SwiftData MemoryEntity scope="global" | memorize(scope="global") |
| Проектная | SwiftData MemoryEntity scope="<projectId UUID>" | memorize(targetName="Chappie") |
| Тредовая | SwiftData MemoryEntity scope="<threadId UUID>" | memorize(scope="thread") |
| Документация таргетов | `<target>/architecture.md` | write_file вручную |

**АВТОМАТИЧЕСКОЕ ПОДМЕШИВАНИЕ В SYSTEM PROMPT:**
`MemoryManager.buildSystemPrompt(basePrompt:threadId:projectIds:)` собирает полный промпт:
1. Базовый промпт (захардкоженные правила Чаппи)
2. Глобальная память (scope="global") — из SwiftData
3. Проектная память (scope="<projectId>") — для каждого проекта в треде
4. Тредовая память (scope="<threadId>") — контекст текущей задачи

**УМНЫЙ SCOPE-МАППИНГ (IT-08 ✅):**
`ToolExecutionService.resolveScope()` маппирует параметры инструментов → UUID scope:
- `scope="global"` → "global"
- `scope="thread"` → UUID активного треда (из ActiveMemoryContext.threadId)
- `targetName="Chappie"` → UUID проекта с именем "Chappie" (из ActiveMemoryContext.projects)

**ActiveMemoryContext передаётся из ChappieViewModel:**
`syncActiveMemoryContext()` собирает реальные UUID из activeThread + activeProjects
и передаёт в ToolExecutionService через `setActiveMemoryContext()`.
Вызывается при: selectThread(), addProject(), removeProject(), reloadAfterProjectChange().

**РАЗРЕШЕНИЕ КОНФЛИКТОВ (IT-08 ✅):**
Если инструкции в разных уровнях памяти противоречат — Чаппи ОСТАНАВЛИВАЕТСЯ,
объясняет конфликт пользователю и ждёт решения. Правило в baseSystemPrompt.

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

### Статус: ✅ ПОЛНОСТЬЮ ЗАВЕРШЁН (IT-01 ✅ → IT-08 ✅)

### Ключевые архитектурные решения

**Принцип JSON-сериализации в SwiftData:**
Вместо того чтобы хранить Swift-модели напрямую в SwiftData (проблемы миграции схемы),
мы храним только примитивы и `Data`. Все сложные объекты сериализуются через JSONEncoder
и хранятся как `Data`. При чтении — JSONDecoder. Это даёт нам свободу эволюции моделей
без болезненных SwiftData-миграций.

**Три уровня памяти в system prompt (IT-03, IT-08 ✅):**
1. Глобальная память — факты о пользователе, стиль общения, кросс-проектные знания
2. Проектная память — архитектура конкретного проекта, пайплайны, договорённости
3. Тредовая память — контекст текущей задачи, временные заметки

**Инструменты управления проектами — паттерн Callback/Closure (IT-07 ✅):**
ToolExecutionService живёт в ChappieCore, ProjectStore/ThreadStore — тоже в ChappieCore,
но управляются из Chappie.app. Прямая ссылка создала бы проблемы с зависимостями.
Решение: ViewModel регистрирует @Sendable замыкания в ToolExecutionService через
`registerProjectHandlers()`. Замыкания вызываются когда Чаппи использует инструменты.

**UUID-based scope памяти (IT-08 ✅):**
Инструменты памяти работают с реальными UUID из SwiftData.
ActiveMemoryContext (threadId UUID + [ProjectInfo{id, name}]) передаётся из ViewModel.
resolveScope() маппирует scope="thread"/"global" и targetName → UUID строку для MemoryStore.

---

## 11. Пошаговый план итераций REFACTOR-THREADS

| # | Итерация | Статус |
|---|---|---|
| IT-01 | SwiftData модели + JSON-сериализация | ✅ ГОТОВО |
| IT-02 | ThreadSettings + динамический AppConfig | ✅ ГОТОВО |
| IT-03 | Трёхуровневая память в system prompt | ✅ ГОТОВО |
| IT-04 | Миграция старых файлов → SwiftData | ✅ ГОТОВО |
| IT-05 | UI: боковая панель тредов | ✅ ГОТОВО |
| IT-06 | UI: плашки проектов в треде | ✅ ГОТОВО |
| IT-07 | Инструменты add/remove project | ✅ ГОТОВО |
| IT-08 | Переработка инструментов памяти (SwiftData + умный UUID scope) | ✅ ГОТОВО |

---

## 12. История чата (TD-03)

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
| 2025-07-XX | IT-08 ✅ ЗАВЕРШЁН: ActiveMemoryContext, UUID-based scope, resolveScope(), syncActiveMemoryContext(), конфликт-резолюция в baseSystemPrompt |
| 2025-07-XX | IT-07 ГОТОВО: add/remove/list_thread_projects инструменты, registerProjectHandlers() в ToolExecutionService |
| 2025-07-XX | IT-06 ГОТОВО: ProjectChipsView, ChappieViewModel addProject/removeProject |
| 2025-07-XX | IT-05 ГОТОВО: ThreadListView, ThreadRowView, SidebarView с тредами |
| 2025-07-XX | IT-04 ГОТОВО: MigrationService (chat_history.json + semantic.json → SwiftData) |
| 2025-07-XX | IT-03 ГОТОВО: MemoryStore (SwiftData CRUD), buildSystemPrompt() с трёхуровневой памятью |
| 2025-07-XX | IT-02 ГОТОВО: динамический AppConfig, tokenBudget = maxMessages × 500 |
| 2025-07-XX | IT-01 ГОТОВО: SwiftData модели (ThreadEntity, ProjectEntity, MemoryEntity) |
| 2025-07-11 | РЕШЕНО TD-01: исправлен дедлок Pipe в BuildTools.swift |
| 2025-07-10 | КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: удалён XcodeDocsGroupManager |
