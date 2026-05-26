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

### Статус: ✅ ЗАВЕРШЁН (IT-01 ✅, IT-02 ✅, IT-03 ✅, IT-04 ✅, IT-05 ✅, IT-06 ✅, IT-07 ✅)

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

**ProjectMetadata — публичный init (IT-06 ✅):**
Аналогично ThreadMetadata — добавлен явный public init в ProjectMetadata.
Используется в Preview и при создании объектов в UI-таргете.

**addProject / removeProject — атомарное обновление (IT-06 ✅):**
ViewModel хранит актуальный список projectIds в activeThread.
При изменении — вычисляет новый массив и вызывает `updateProjectBindings()` целиком.
Это гарантирует консистентность без риска рассинхронизации.

**ProjectChipsView — "тупой компонент" (IT-06 ✅):**
Не знает о SwiftData, ProjectStore или ThreadStore напрямую.
Все данные — через параметры, все действия — через коллбэки.
NSOpenPanel открывается прямо из View (стандартный паттерн macOS).

**Инструменты управления проектами — паттерн Callback/Closure (IT-07 ✅):**
ToolExecutionService живёт в ChappieCore, ProjectStore/ThreadStore — тоже в ChappieCore,
но управляются из Chappie.app. Прямая ссылка создала бы проблемы с зависимостями.
Решение: ViewModel регистрирует @Sendable замыкания в ToolExecutionService через
`registerProjectHandlers()`. Замыкания вызываются когда Чаппи использует инструменты.

**SENDABLE + MainActor мост (IT-07 ✅):**
Замыкания @Sendable не могут захватить self (@MainActor) напрямую.
Используем `withCheckedContinuation + Task { @MainActor [weak self] in }` для безопасного
доступа к свойствам ViewModel из @Sendable замыкания.
`[weak self]` предотвращает retain-цикл: ViewModel → ToolExecutionService → замыкание → ViewModel.

**add_project_to_thread без NSOpenPanel (IT-07 ✅):**
Чаппи не может открыть NSOpenPanel (нет доступа к UI).
При вызове инструмента — ищем существующий проект по displayName или создаём новый
с пустым bookmark (`Data()`). Bookmark добавит пользователь через UI при необходимости.
Для целей памяти и контекста проекта bookmark не нужен.

**Статические методы для @Sendable (IT-07 ✅):**
`performAddProjectByName` и `performRemoveProjectByName` — static методы.
Статические методы не захватывают self — безопасны для вызова из @Sendable замыкания.
Принимают все зависимости явными параметрами (DI через параметры).

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

### UI — плашки проектов в треде (IT-06 ✅)

**Файлы:**
- `Chappie/Views/Chat/ProjectChipsView.swift` — горизонтальный ряд чипов проектов

**Поведение:**
- Горизонтальный скролл с чипами-тегами проектов
- Hover на чипе — появляется кнопка "×" для удаления проекта из треда
- Кнопка "+" → NSOpenPanel → выбор папки → создание/добавление проекта
- При удалении — UUID убирается из projectBindingsJSON (ProjectEntity НЕ удаляется)
- Компонент скрыт пока activeThread == nil (анимированное появление)

### Инструменты управления проектами (IT-07 ✅)

**Новые инструменты Чаппи:**
- `add_project_to_thread(display_name:)` — добавить проект по имени папки
- `remove_project_from_thread(display_name:)` — убрать проект из треда
- `list_thread_projects()` — показать список проектов текущего треда

**Изменённые файлы:**
- `ChappieCore/.../ToolExecutionService.swift`
  — добавлены 3 инструмента в availableTools
  — добавлены 3 case в execute()
  — добавлены приватные свойства addProjectHandler, removeProjectHandler, listProjectsHandler
  — добавлен публичный метод registerProjectHandlers()
- `Chappie/ChappieViewModel.swift`
  — добавлен registerProjectToolHandlers() — регистрация callback'ов
  — добавлены static performAddProjectByName() и performRemoveProjectByName()
  — добавлен reloadAfterProjectChange() — обновление UI после изменений
  — setModelContainer() вызывает registerProjectToolHandlers() после создания сторов
  — initializeServices() вызывает registerProjectToolHandlers() если сторы уже есть

---

## 11. REFACTOR-THREADS — Пошаговый план итераций

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

### 🎉 REFACTOR-THREADS ЗАВЕРШЁН ПОЛНОСТЬЮ!

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
| 2025-07-XX | IT-07 ГОТОВО: add/remove/list_thread_projects инструменты, registerProjectHandlers() в ToolExecutionService, паттерн Callback/Closure + withCheckedContinuation, static performAdd/RemoveProjectByName |
| 2025-07-XX | IT-06 ГОТОВО: ProjectChipsView (чипы проектов с hover/add/remove), ContentView условный рендер, ChappieViewModel addProject/removeProject, ThreadStore updateProjectBindings, ProjectStore loadProjects(ids:) |
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
