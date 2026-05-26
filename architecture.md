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
├── chat_history.json                   # История чата (корень проекта, управляется ChatHistoryManager)
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

**ВНИМАНИЕ:** `chat_history.json` и `semantic.json` будут заменены на SwiftData
в рамках REFACTOR-THREADS (см. раздел 10). Файлы останутся до завершения миграции.

**Путь:** `<workspaceURL>/chat_history.json` (прямо в корне проекта)

Управляется `ChatHistoryManager` в ChappieCore.

**Ключевые решения:**
- Файл лежит в КОРНЕ воркспейса (не в AI_Docs/ — папка упразднена).
- Автоматическое подрезание до 100 сообщений при каждом сохранении.
- 100 сообщений = ~20-50 диалоговых пар, достаточно для работы.
- Оркестратор всё равно берёт только последние maxMessagesInContext (теперь из ThreadSettings).

**ВАЖНО:** При рефакторинге — путь нельзя менять без обновления `ChatHistoryManager.swift`.

---

## 6. Структура памяти (TD-03) — ОБНОВЛЕНО IT-03

Три уровня памяти:

| Уровень | Хранилище | Управляется |
|---|---|---|
| Глобальная (кросс-проектная) | SwiftData MemoryEntity scope="global" + legacy ~/Documents/Chappie/semantic.json | MemoryStore + MemoryManager |
| Проектная | SwiftData MemoryEntity scope="<projectId>" | MemoryStore |
| Тредовая | SwiftData MemoryEntity scope="<threadId>" | MemoryStore |
| Документация таргетов | `<target>/architecture.md` | Чаппи вручную через write_file |

**АВТОМАТИЧЕСКОЕ ПОДМЕШИВАНИЕ В SYSTEM PROMPT (IT-03):**
`MemoryManager.buildSystemPrompt(basePrompt:threadId:projectIds:)` собирает полный промпт:
1. Базовый промпт (захардкоженные правила Чаппи)
2. Глобальная память (scope="global") — из SwiftData + legacy файл
3. Проектная память (scope="<projectId>") — для каждого проекта в треде
4. Тредовая память (scope="<threadId>") — контекст текущей задачи

**ДВОЙНОЙ БЭКЕНД (до IT-04):**
- Инструменты memorize/recall → пишут в ~/Documents/Chappie/semantic.json (legacy)
- buildSystemPrompt() → читает из MemoryStore (SwiftData) + legacy файл (дедупликация)
- После IT-04 (MigrationService) → только SwiftData

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

### Статус: 🔄 В ПРОЦЕССЕ (IT-01 ✅, IT-02 ✅, IT-03 ✅)

### Контекст и мотивация

Сейчас у Чаппи один глобальный чат без тредов и без привязки к проектам.
Цель рефакторинга — сделать полноценную мультитредовую систему как в Claude/ChatGPT,
но с уникальной фичей: выбор одного или нескольких проектов для каждого треда.

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

**Автоматическое подмешивание (IT-03 ✅):**
`MemoryManager.buildSystemPrompt()` вызывается перед каждым запросом в `AIOrchestrator.process()`.
Чаппи ВСЕГДА видит всю свою память — не нужно явно вызывать recall.

**Двойной бэкенд памяти (до IT-04):**
- legacy: ~/Documents/Chappie/semantic.json (инструменты memorize/recall)
- новый: SwiftData MemoryStore (buildSystemPrompt читает отсюда + из legacy)
- После IT-04: только SwiftData

**MemoryContext (IT-03 ✅):**
```swift
struct MemoryContext: Sendable {
    let threadId: UUID?      // для тредовой памяти
    let projectIds: [UUID]   // для проектной памяти
    static let empty = MemoryContext()  // фолбэк без памяти
}
```
Передаётся в `process()` как параметр. До IT-05 = `.empty`.

**Формула tokenBudget (IT-02 ✅):**
```
tokenBudget = maxMessagesInContext × 500
```
Диапазон: 10 сообщений = 5,000 токенов ... 100 сообщений = 50,000 токенов.

**AppConfig — динамический (IT-02 ✅):**
- `AppConfig.shared` — дефолт (20 сообщений, 10,000 токенов)
- `AppConfig(maxMessagesInContext:)` — создаётся из настроек треда
- `AppConfig(settings: ThreadSettings)` — фабричный метод из ThreadSettings
- `AIOrchestrator.process()` принимает `config: AppConfig` как параметр

### SwiftData схема (тонкий слой хранилища)

```
ThreadEntity (SwiftData)
├── id: UUID
├── title: String
├── createdAt: Date
├── updatedAt: Date
├── messagesJSON: Data          ← [ChatMessage] сериализованы через JSONEncoder
├── settingsJSON: Data          ← ThreadSettings сериализован через JSONEncoder
└── projectBindingsJSON: Data   ← [UUID] — список ID проектов в этом треде

ProjectEntity (SwiftData)
├── id: UUID
├── displayName: String
├── bookmarkData: Data          ← security-scoped bookmark для доступа к папке
├── createdAt: Date
└── settingsJSON: Data          ← ProjectSettings сериализован через JSONEncoder

MemoryEntity (SwiftData)
├── id: UUID
├── scope: String               ← "global" | "<projectId>" | "<threadId>"
└── entriesJSON: Data           ← [MemoryEntry] сериализованы через JSONEncoder
```

### UI — боковая панель тредов

- Классическая боковая панель как в Claude/ChatGPT
- Список тредов, сортировка по updatedAt (последний активный — сверху)
- Кнопка "Новый тред" внизу панели
- Название треда — первые слова первого сообщения (автогенерация)

### UI — плашки проектов в треде

- В верхней части чата — горизонтальный ряд чипов/тегов с именами проектов
- Кнопка `+` для добавления проекта из списка существующих
- Кнопка `×` на каждом чипе для удаления проекта из треда
- Чаппи сам может добавлять/удалять проекты через инструменты в процессе разговора

### Инструменты управления тредом (новые MCP-инструменты)

- `add_project_to_thread(projectId)` — Чаппи добавляет проект в текущий тред
- `remove_project_from_thread(projectId)` — Чаппи удаляет проект из треда

### Миграция при первом запуске

При первом запуске новой версии:
1. Читаем `chat_history.json` из корня воркспейса
2. Создаём один тред "Основной" и переносим историю в него
3. Читаем `~/Documents/Chappie/semantic.json`
4. Переносим записи в MemoryEntity с scope="global"
5. Старые файлы НЕ удаляем сразу — оставляем как backup

---

## 11. REFACTOR-THREADS — Пошаговый план итераций

### ВАЖНО ДЛЯ ЧАППИ: Этот план написан так, чтобы его можно было выполнять
### итерациями с полной перекомпиляцией после каждой. После каждой итерации —
### обновляй статус в этом файле и делай коммит.

---

### ✅ / 🔲 Статус итераций

| # | Итерация | Статус |
|---|---|---|
| IT-01 | SwiftData модели + JSON-сериализация | ✅ ГОТОВО |
| IT-02 | ThreadSettings + динамический AppConfig | ✅ ГОТОВО |
| IT-03 | Трёхуровневая память в system prompt | ✅ ГОТОВО |
| IT-04 | Миграция старых файлов → SwiftData | 🔲 |
| IT-05 | UI: боковая панель тредов | 🔲 |
| IT-06 | UI: плашки проектов в треде | 🔲 |
| IT-07 | Инструменты add/remove project | 🔲 |

---

### IT-01: SwiftData модели + JSON-сериализация ✅ ГОТОВО

**Созданные файлы:**
- `ChappieCore/Sources/ChappieCore/Models/ThreadModels.swift`
- `ChappieCore/Sources/ChappieCore/Models/ProjectModels.swift`
- `ChappieCore/Sources/ChappieCore/Models/MemoryModels.swift`
- `ChappieCore/Sources/ChappieCore/Services/ThreadStore.swift`
- `ChappieCore/Sources/ChappieCore/Services/ProjectStore.swift`
- `Chappie/ChappieApp.swift` — добавлен ModelContainer

---

### IT-02: ThreadSettings + динамический AppConfig ✅ ГОТОВО

**Изменённые файлы:**
- `ChappieCore/Sources/ChappieCore/Models/AppConfig.swift`
- `ChappieCore/Sources/ChappieCore/Services/AIOrchestrator.swift`
- `Chappie/ChappieViewModel.swift`
- `ChappieCoreTests/AppConfigTests.swift`

---

### IT-03: Трёхуровневая память в system prompt ✅ ГОТОВО

**Созданные файлы:**
- `ChappieCore/Sources/ChappieCore/Services/MemoryStore.swift`
  — actor для CRUD памяти в SwiftData
  — readEntriesForScopes() — массовая загрузка для buildSystemPrompt()
  — importEntries() — для MigrationService в IT-04

**Изменённые файлы:**
- `ChappieCore/Sources/ChappieCore/Services/MemoryManager.swift`
  — добавлен setMemoryStore(store: MemoryStore)
  — добавлен buildSystemPrompt(basePrompt:threadId:projectIds:)
  — добавлен loadLegacyMemoryForPrompt() — читает legacy semantic.json
  — добавлен buildMemoryBlock() — форматирует блок памяти с дедупликацией SwiftData vs legacy
- `ChappieCore/Sources/ChappieCore/Services/AIOrchestrator.swift`
  — добавлен MemoryContext: Sendable struct (threadId + projectIds)
  — systemPrompt переименован в baseSystemPrompt
  — init принимает memoryManager: MemoryManager
  — process() принимает memoryContext: MemoryContext = .empty
  — вызывает buildSystemPrompt() перед каждым запросом
- `Chappie/ChappieViewModel.swift`
  — добавлен activeMemoryContext: MemoryContext = .empty
  — добавлен setModelContainer(_ container: ModelContainer)
  — добавлен memoryStore: MemoryStore? (опциональный)
  — initializeServices() подключает MemoryStore к MemoryManager
  — send() передаёт memoryContext в process()
- `Chappie/ContentView.swift`
  — @Environment(\.modelContext) private var modelContext
  — .onAppear { viewModel.setModelContainer(modelContext.container) }

---

### IT-04: Миграция старых файлов → SwiftData

**Цель:** При первом запуске перенести `chat_history.json` и `semantic.json` в SwiftData.

**Файлы к созданию:**
- `ChappieCore/Sources/ChappieCore/Services/MigrationService.swift`
  — `migrate()` — идемпотентный, проверяет флаг `UserDefaults["migration_v1_done"]`
  — читает `chat_history.json`, создаёт тред "Основной", переносит историю
  — читает `semantic.json`, переносит в MemoryEntity с scope="global" через MemoryStore.importEntries()

**Файлы к изменению:**
- `Chappie/ChappieViewModel.swift` — вызвать MigrationService после setModelContainer()

**Критерий готовности:** Проект компилируется. Старая история видна в новом треде.

**Зависимости:** IT-01, IT-03 (MemoryStore.importEntries()).

---

### IT-05: UI — боковая панель тредов

**Цель:** Классическая боковая панель с тредами как в Claude/ChatGPT.

**Файлы к созданию:**
- `Chappie/Views/Sidebar/ThreadListView.swift`
- `Chappie/Views/Sidebar/ThreadRowView.swift`

**Файлы к изменению:**
- `Chappie/Views/Sidebar/SidebarView.swift`
- `Chappie/ChappieViewModel.swift` — activeThread, threads, createThread(), selectThread(), deleteThread()
- `Chappie/ContentView.swift` — NavigationSplitView

**При завершении IT-05:**
- `activeMemoryContext` заполняется из активного треда (threadId + projectIds)
- `activeThreadSettings` загружается из ThreadStore

**Критерий готовности:** Проект компилируется. Можно создавать треды и переключаться между ними.

**Зависимости:** IT-01, IT-04.

---

### IT-06: UI — плашки проектов в треде

**Цель:** Горизонтальный ряд чипов проектов в верхней части чата.

**Файлы к созданию:**
- `Chappie/Views/Chat/ProjectChipsView.swift`

**Файлы к изменению:**
- `Chappie/Views/Chat/ChatScrollView.swift`
- `Chappie/ChappieViewModel.swift` — addProject(), removeProject()

**Критерий готовности:** Проект компилируется. Можно добавлять/удалять проекты в треде через UI.

**Зависимости:** IT-01, IT-05.

---

### IT-07: Инструменты add/remove project

**Цель:** Чаппи сам может добавлять/удалять проекты из треда в процессе разговора.

**Файлы к изменению:**
- `ChappieCore/Sources/ChappieCore/Services/ToolExecutionService.swift`
- `ChappieCore/Sources/ChappieCore/Services/AIOrchestrator.swift`

**Критерий готовности:** Проект компилируется. Чаппи может управлять проектами через tool_use.

**Зависимости:** IT-01, IT-06.

---

## 12. История чата (TD-03)

**Путь:** `<workspaceURL>/chat_history.json` (прямо в корне проекта)

Управляется `ChatHistoryManager` в ChappieCore.

**Ключевые решения:**
- Файл лежит в КОРНЕ воркспейса (не в AI_Docs/ — папка упразднена).
- Автоматическое подрезание до 100 сообщений при каждом сохранении.
- Оркестратор берёт последние maxMessagesInContext (из ThreadSettings треда).

---

## 📚 Changelog

| Date | Change |
|------|--------|
| 2025-07-XX | IT-03 ГОТОВО: MemoryStore (SwiftData CRUD), buildSystemPrompt() с трёхуровневой памятью, MemoryContext, двойной бэкенд (legacy + SwiftData) |
| 2025-07-XX | IT-02 ГОТОВО: динамический AppConfig, tokenBudget = maxMessages × 500 |
| 2025-07-XX | IT-01 ГОТОВО: SwiftData модели (ThreadEntity, ProjectEntity, MemoryEntity), ThreadStore, ProjectStore, ModelContainer |
| 2025-07-11 | РЕШЕНО TD-01: исправлен дедлок Pipe в BuildTools.swift |
| 2025-07-10 | КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: удалён XcodeDocsGroupManager |
| 2025-07-10 | TD-01: зафиксированы зависания build_project |
| 2025-07-10 | Починен сломанный project.pbxproj |
| 2025-07-10 | Добавлена группа 📚 Docs в project.pbxproj |
| 2025-06 | TD-03: рефакторинг AI_Docs/ → один файл architecture.md на таргет |
| 2025-07-XX | REFACTOR-THREADS: зафиксирован план итераций IT-01..IT-07 |
