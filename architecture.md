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
- Оркестратор всё равно берёт только последние 12 (maxMessagesInContext).

**ВАЖНО:** При рефакторинге — путь нельзя менять без обновления `ChatHistoryManager.swift`.

---

## 6. Структура памяти (TD-03) — УСТАРЕВАЕТ

Три уровня памяти:

| Уровень | Файл | Управляется |
|---|---|---|
| Глобальная (кросс-проектная) | `~/Documents/Chappie/semantic.json` | `MemoryManager` (scope: global) |
| Локальная (таргет) | `<target>/architecture.md` | Чаппи вручную через write_file |
| История чата | `<workspaceURL>/chat_history.json` | `ChatHistoryManager` |

Папки `AI_Docs/` во всех таргетах **упразднены** — они были избыточны.
Каждый таргет имеет только `architecture.md` в своём корне.

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

**Правильная структура PBXGroup в pbxproj:**
```
87BAA46F2FBEED3A001DDBED = {          ← корневая группа (без имени)
    isa = PBXGroup;
    children = (
        87DOCS0000000000000000000,    ← ссылка на группу Docs (ID объекта)
        87BAA47A...,                  ← Chappie
        874865FB...,                  ← ChappieCoreTests
        ...
    );
};

87DOCS0000000000000000000 = {         ← ОТДЕЛЬНЫЙ объект группы Docs
    isa = PBXGroup;
    name = "📚 Docs";
    children = ( ... );
};

87BAA4792FBEED3A001DDBED = {          ← ОТДЕЛЬНЫЙ объект Products
    isa = PBXGroup;
    name = Products;
    ...
};
```

**КРИТИЧНО:** Каждый PBXGroup — это ОТДЕЛЬНЫЙ объект в секции `/* Begin PBXGroup section */`.
Нельзя вкладывать определение одного объекта внутрь `children = (` другого!
`children` содержит только ID (ссылки), сами объекты определяются отдельно.

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
// Запускаем параллельное чтение ДО process.run()
readGroup.enter()
DispatchQueue.global(qos: .utility).async {
    stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    readGroup.leave()
}
// ... аналогично для stderr ...

try process.run()
process.waitUntilExit()   // теперь не зависает — Pipe читается параллельно
readGroup.wait()           // ждём завершения чтения
```

### Причина 2: Нет явного destination (ИСПРАВЛЕНО 2025-07-11)

Без явного `arch` xcodebuild на macOS 26 beta зависал, выбирая между устройствами.

**Решение:** добавлен явный `-destination "platform=macOS,arch=arm64"` для обеих команд.

### Причина 3: Таймаут как последняя линия защиты

Даже после исправления дедлока — таймаут 300с остаётся как страховка:
```swift
let killWorkItem = DispatchWorkItem {
    if process.isRunning {
        timedOut = true
        process.terminate()
    }
}
DispatchQueue.global(qos: .background).asyncAfter(
    deadline: .now() + kBuildTimeoutSeconds,
    execute: killWorkItem
)
```

---

## 9. Техдолг

| ID | Проблема | Приоритет |
|----|----------|-----------|
| TD-01 | `build_project` зависал — РЕШЕНО (2025-07-11): дедлок Pipe исправлен, параллельное чтение, таймаут 300с + явный destination arm64 | ✅ |
| TD-02 | Тесты `ChappieCoreTests` требуют ручного выбора таргета в Xcode перед ⌘+U. Неочевидно для пользователя. | Низкий |

---

## 10. REFACTOR-THREADS — Большой рефакторинг: треды, проекты, SwiftData

### Статус: 🔲 НЕ НАЧАТ

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

**Три уровня памяти в system prompt:**
1. Глобальная память — факты о пользователе, стиль общения, кросс-проектные знания
2. Проектная память — архитектура конкретного проекта, пайплайны, договорённости
3. Тредовая память — контекст текущей задачи, временные заметки

**Формула tokenBudget:**
```
tokenBudget = maxMessagesInContext × 500
```
Диапазон: 10 сообщений = 5,000 токенов ... 100 сообщений = 50,000 токенов.
Механизм двойного отсечения наследуется без изменений:
1. Жёсткий лимит по количеству (maxMessagesInContext) — применяется первым
2. Мягкий лимит по токенам (tokenBudget) — применяется вторым
3. Summary-сжатие старых длинных сообщений — работает под капотом

**AppConfig становится динамическим:**
Вместо глобального синглтона с захардкоженными значениями — конфиг создаётся
из настроек треда и передаётся в `AIOrchestrator.process()` как параметр.
`AppConfig.shared` остаётся как дефолтный конфиг для обратной совместимости.

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

### ThreadSettings (Swift struct, Codable)

```swift
struct ThreadSettings: Codable {
    var maxMessagesInContext: Int   // 10...100, по умолчанию 20
    // tokenBudget вычисляется: maxMessagesInContext × 500
    // recentFullMessages, summaryThreshold — под капотом, не меняются
    // Будущие расширения: язык ответа, режим, доступные инструменты
}
```

### ProjectSettings (Swift struct, Codable)

```swift
struct ProjectSettings: Codable {
    var preferredLanguage: String   // язык комментариев и ответов
    // Будущие расширения: пайплайн, архитектурные ограничения
}
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
| IT-01 | SwiftData модели + JSON-сериализация | 🔲 |
| IT-02 | ThreadSettings + динамический AppConfig | 🔲 |
| IT-03 | Трёхуровневая память в system prompt | 🔲 |
| IT-04 | Миграция старых файлов → SwiftData | 🔲 |
| IT-05 | UI: боковая панель тредов | 🔲 |
| IT-06 | UI: плашки проектов в треде | 🔲 |
| IT-07 | Инструменты add/remove project | 🔲 |

---

### IT-01: SwiftData модели + JSON-сериализация

**Цель:** Создать фундамент — SwiftData схему с JSON-сериализацией.

**Файлы к созданию:**
- `ChappieCore/Sources/ChappieCore/Models/ThreadModels.swift`
  — `ThreadEntity`, `ThreadSettings`, `ChatMessage` расширение с Codable
- `ChappieCore/Sources/ChappieCore/Models/ProjectModels.swift`
  — `ProjectEntity`, `ProjectSettings`
- `ChappieCore/Sources/ChappieCore/Models/MemoryModels.swift`
  — `MemoryEntity`, `MemoryEntry`
- `ChappieCore/Sources/ChappieCore/Services/ThreadStore.swift`
  — actor, CRUD операции над тредами через SwiftData
- `ChappieCore/Sources/ChappieCore/Services/ProjectStore.swift`
  — actor, CRUD операции над проектами через SwiftData

**Файлы к изменению:**
- `ChappieCore/Sources/ChappieCore/ChappieCore.swift` — добавить публичный API новых сервисов
- `Chappie/ChappieApp.swift` — добавить `.modelContainer()` для SwiftData

**Критерий готовности:** Проект компилируется. Можно создать тред и прочитать его обратно.

**Зависимости:** Нет. Это фундамент.

---

### IT-02: ThreadSettings + динамический AppConfig

**Цель:** `AppConfig` принимается в `process()` как параметр, `tokenBudget` вычисляется из `maxMessagesInContext`.

**Файлы к изменению:**
- `ChappieCore/Sources/ChappieCore/Models/AppConfig.swift`
  — добавить `init(maxMessagesInContext:)`, вычисляемый `tokenBudget`
  — `AppConfig.shared` остаётся как дефолт (20 сообщений = 10,000 токенов)
- `ChappieCore/Sources/ChappieCore/Services/AIOrchestrator.swift`
  — `process()` принимает `config: AppConfig` как параметр (с дефолтом `AppConfig.shared`)
- `Chappie/ChappieViewModel.swift`
  — при вызове `process()` передаёт конфиг из настроек активного треда

**Критерий готовности:** Проект компилируется. `tokenBudget` вычисляется корректно.

**Зависимости:** IT-01 (нужен `ThreadSettings`).

---

### IT-03: Трёхуровневая память в system prompt

**Цель:** System prompt автоматически включает глобальную + проектную + тредовую память.

**Файлы к изменению:**
- `ChappieCore/Sources/ChappieCore/Services/MemoryManager.swift`
  — добавить методы `loadGlobalMemory()`, `loadProjectMemory(projectId:)`, `loadThreadMemory(threadId:)`
  — добавить метод `buildSystemPrompt(threadId:projectIds:)` — собирает полный system prompt
- `ChappieCore/Sources/ChappieCore/Services/AIOrchestrator.swift`
  — использует `buildSystemPrompt()` вместо захардкоженного промпта

**Критерий готовности:** Проект компилируется. System prompt содержит все три уровня памяти.

**Зависимости:** IT-01 (MemoryEntity), IT-02 (динамический конфиг).

---

### IT-04: Миграция старых файлов → SwiftData

**Цель:** При первом запуске перенести `chat_history.json` и `semantic.json` в SwiftData.

**Файлы к созданию:**
- `ChappieCore/Sources/ChappieCore/Services/MigrationService.swift`
  — `migrate()` — идемпотентный, проверяет флаг `UserDefaults["migration_v1_done"]`
  — читает `chat_history.json`, создаёт тред "Основной", переносит историю
  — читает `semantic.json`, переносит в MemoryEntity с scope="global"

**Файлы к изменению:**
- `Chappie/ChappieApp.swift` — вызвать `MigrationService.migrate()` при старте

**Критерий готовности:** Проект компилируется. Старая история видна в новом треде.

**Зависимости:** IT-01.

---

### IT-05: UI — боковая панель тредов

**Цель:** Классическая боковая панель с тредами как в Claude/ChatGPT.

**Файлы к созданию:**
- `Chappie/Views/Sidebar/ThreadListView.swift`
  — список тредов с сортировкой по updatedAt
  — кнопка "Новый тред"
  — выбор активного треда
- `Chappie/Views/Sidebar/ThreadRowView.swift`
  — одна строка треда: название + дата

**Файлы к изменению:**
- `Chappie/Views/Sidebar/SidebarView.swift`
  — интегрировать `ThreadListView` вместо текущего содержимого
- `Chappie/ChappieViewModel.swift`
  — добавить `activeThread: ThreadEntity?`
  — добавить `threads: [ThreadEntity]`
  — методы `createThread()`, `selectThread(_:)`, `deleteThread(_:)`
- `Chappie/ContentView.swift`
  — подключить `NavigationSplitView` с боковой панелью

**Критерий готовности:** Проект компилируется. Можно создавать треды и переключаться между ними.

**Зависимости:** IT-01, IT-04.

---

### IT-06: UI — плашки проектов в треде

**Цель:** Горизонтальный ряд чипов проектов в верхней части чата.

**Файлы к созданию:**
- `Chappie/Views/Chat/ProjectChipsView.swift`
  — горизонтальный ScrollView с чипами
  — кнопка `+` → sheet со списком проектов для добавления
  — кнопка `×` на каждом чипе для удаления

**Файлы к изменению:**
- `Chappie/Views/Chat/ChatScrollView.swift`
  — добавить `ProjectChipsView` в верхней части
- `Chappie/ChappieViewModel.swift`
  — методы `addProject(_:toThread:)`, `removeProject(_:fromThread:)`

**Критерий готовности:** Проект компилируется. Можно добавлять/удалять проекты в треде через UI.

**Зависимости:** IT-01, IT-05.

---

### IT-07: Инструменты add/remove project

**Цель:** Чаппи сам может добавлять/удалять проекты из треда в процессе разговора.

**Файлы к изменению:**
- `ChappieCore/Sources/ChappieCore/Services/ToolExecutionService.swift`
  — добавить обработку `add_project_to_thread` и `remove_project_from_thread`
- `ChappieCore/Sources/ChappieCore/Services/AIOrchestrator.swift`
  — добавить описание новых инструментов в список tools

**Критерий готовности:** Проект компилируется. Чаппи может управлять проектами через tool_use.

**Зависимости:** IT-01, IT-06.

---

## 12. История чата (TD-03)

**Путь:** `<workspaceURL>/chat_history.json` (прямо в корне проекта)

Управляется `ChatHistoryManager` в ChappieCore.

**Ключевые решения:**
- Файл лежит в КОРНЕ воркспейса (не в AI_Docs/ — папка упразднена).
- Автоматическое подрезание до 100 сообщений при каждом сохранении.
- 100 сообщений = ~20-50 диалоговых пар, достаточно для работы.
- Оркестратор всё равно берёт только последние 12 (maxMessagesInContext).

**ВАЖНО:** При рефакторинге — путь нельзя менять без обновления `ChatHistoryManager.swift`.

---

## 📚 Changelog

| Date | Change |
|------|--------|
| 2025-07-11 | РЕШЕНО TD-01 корень: исправлен дедлок Pipe в BuildTools.swift — параллельное чтение stdout/stderr через DispatchQueue |
| 2025-07-11 | РЕШЕНО TD-01: добавлен таймаут 300с + terminate() в BuildTools.swift; явный destination arm64 |
| 2025-07-10 | КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: удалён XcodeDocsGroupManager, группа 📚 Docs теперь статическая |
| 2025-07-10 | TD-01: зафиксированы зависания build_project; TD-02: тесты требуют выбора таргета |
| 2025-07-10 | Починен сломанный project.pbxproj (неправильная вложенность PBXGroup вызывала "Failed to load container") |
| 2025-07-10 | Добавлена группа 📚 Docs в project.pbxproj для навигации по architecture.md файлам |
| 2025-06 | TD-03: рефакторинг AI_Docs/ → один файл architecture.md на таргет; chat_history.json переехал в корень воркспейса; подрезание до 100 сообщений |
| 2025-07-XX | REFACTOR-THREADS: зафиксирован план итераций IT-01..IT-07 |
