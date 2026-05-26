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

## 6. Структура памяти (TD-03) — ОБНОВЛЕНО IT-04

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

### Статус: 🔄 В ПРОЦЕССЕ (IT-01 ✅, IT-02 ✅, IT-03 ✅, IT-04 ✅, IT-05 ✅)

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

**Миграция legacy-данных (IT-04 ✅):**
`MigrationService.migrate<T: Codable>()` — Generic метод, не зависит от ChatMessage.
Идемпотентен: флаг `UserDefaults["migration_v1_done"]`.
Вызывается из `ChappieViewModel.setModelContainer()` асинхронно.

**Двойной бэкенд памяти (до IT-04):**
- legacy: ~/Documents/Chappie/semantic.json (инструменты memorize/recall)
- новый: SwiftData MemoryStore (buildSystemPrompt читает отсюда + из legacy)
- После IT-04: только SwiftData (миграция выполнена)

**MemoryContext (IT-03 ✅):**
```swift
struct MemoryContext: Sendable {
    let threadId: UUID?      // для тредовой памяти
    let projectIds: [UUID]   // для проектной памяти
    static let empty = MemoryContext()  // фолбэк без памяти
}
```
Передаётся в `process()` как параметр. С IT-05 заполняется из активного треда.

**Формула tokenBudget (IT-02 ✅):**
```
tokenBudget = maxMessagesInContext × 500
```
Диапазон: 10 сообщений = 5,000 токенов ... 100 сообщений = 50,000 токенов.

**AppConfig — динамический (IT-02 ✅):**
- `AppConfig.shared` — дефолт (20 сообщений, 10,000 токенов)
- `AppConfig(maxMessagesInContext:)` — создаётся из числа
- `AppConfig(settings: ThreadSettings)` — фабричный метод из ThreadSettings
- `AIOrchestrator.process()` принимает `config: AppConfig` как параметр

**ThreadMetadata — публичный init (IT-05 ✅):**
Добавлен публичный memberwise init в ThreadMetadata для Preview и тестов.
Swift автогенерирует memberwise init как internal — для UI-таргета нужен явный public.

**isLoadingThread флаг (IT-05 ✅):**
При загрузке истории треда из SwiftData messages.didSet НЕ должен сохранять
в legacy ChatHistoryManager (иначе перезапишет историю другого треда).
Флаг isLoadingThread позволяет saveMessages() пропустить сохранение.

**MemberImportVisibility (Swift 6 / Xcode 26):**
Фича требует явного `import ChappieCore` в каждом файле UI-таргета, где используются
типы из ChappieCore. ContentView.swift получил явный `import ChappieCore`.

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

### UI — боковая панель тредов (IT-05 ✅)

**Файлы:**
- `Chappie/Views/Sidebar/ThreadListView.swift` — список тредов (ForEach)
- `Chappie/Views/Sidebar/ThreadRowView.swift` — строка треда с hover/rename/delete
- `Chappie/Views/Sidebar/SidebarView.swift` — обновлён, добавлена секция тредов + кнопка "Новый тред"

**Поведение:**
- Список тредов сортируется по updatedAt DESC (самый свежий — сверху)
- Активный тред подсвечивается акцентным цветом
- Hover — показывается кнопка удаления
- Двойной клик — inline переименование через TextField
- Контекстное меню (правый клик) — переименовать, удалить
- Кнопка "Новый тред" закреплена внизу панели
- При удалении последнего треда — автоматически создаётся новый

**Автоматическое управление тредами в ViewModel:**
- При старте: loadThreadsAndSelectActive() — загружает треды и выбирает первый
- При пустом списке: автоматически создаётся "Новый тред"
- selectThread(): загружает историю + настройки + обновляет MemoryContext
- После отправки сообщения: история сохраняется в активный тред через ThreadStore

### UI — плашки проектов в треде (IT-06 — следующая)

- В верхней части чата — горизонтальный ряд чипов/тегов с именами проектов
- Кнопка `+` для добавления проекта из списка существующих
- Кнопка `×` на каждом чипе для удаления проекта из треда
- Чаппи сам может добавлять/удалять проекты через инструменты в процессе разговора

### Инструменты управления тредом (IT-07 — после IT-06)

- `add_project_to_thread(projectId)` — Чаппи добавляет проект в текущий тред
- `remove_project_from_thread(projectId)` — Чаппи удаляет проект из треда

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
| IT-04 | Миграция старых файлов → SwiftData | ✅ ГОТОВО |
| IT-05 | UI: боковая панель тредов | ✅ ГОТОВО |
| IT-06 | UI: плашки проектов в треде | 🔲 |
| IT-07 | Инструменты add/remove project | 🔲 |

---

### IT-05: UI — боковая панель тредов ✅ ГОТОВО

**Созданные файлы:**
- `Chappie/Views/Sidebar/ThreadListView.swift`
  — ForEach по тредам, делегирует рендер ThreadRowView
- `Chappie/Views/Sidebar/ThreadRowView.swift`
  — строка треда: hover-кнопка удаления, inline-переименование, контекстное меню
  — RelativeDateTimeFormatter для отображения даты (ru_RU)

**Изменённые файлы:**
- `Chappie/Views/Sidebar/SidebarView.swift`
  — добавлена секция "Треды" с ThreadListView
  — кнопка "Новый тред" закреплена внизу (VStack + Divider)
  — новые параметры: threads, selectedThreadId, onSelectThread, onCreateThread, onDeleteThread, onRenameThread
- `Chappie/ChappieViewModel.swift`
  — threads: [ThreadMetadata] — список для боковой панели
  — activeThread: ThreadMetadata? — активный тред
  — isLoadingThread: Bool — флаг предотвращения записи в legacy при загрузке треда
  — loadThreadsAndSelectActive() — загрузка и выбор активного треда
  — selectThread() — переключение треда (загрузка истории + настроек + MemoryContext)
  — createNewThread() — создание нового треда
  — deleteThread() — удаление с защитой от пустого списка
  — renameThread() — переименование
  — saveMessages() — пропускает запись при isLoadingThread
  — send() — после получения ответа сохраняет в ThreadStore
- `Chappie/ContentView.swift`
  — добавлен `import ChappieCore` (MemberImportVisibility Swift 6)
  — SidebarView получает threads, selectedThreadId и все коллбэки
- `ChappieCore/Sources/ChappieCore/Services/ThreadStore.swift`
  — ThreadMetadata добавлен публичный memberwise init

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
- После IT-05 — история хранится в ThreadStore (SwiftData), ChatHistoryManager устаревает.

---

## 📚 Changelog

| Date | Change |
|------|--------|
| 2025-07-XX | IT-05 ГОТОВО: ThreadListView, ThreadRowView, SidebarView с тредами, ChappieViewModel управление тредами, ContentView + import ChappieCore |
| 2025-07-XX | IT-04 ГОТОВО: MigrationService (chat_history.json + semantic.json → SwiftData), 5 тестов, ThreadStore добавлен в ChappieViewModel |
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
