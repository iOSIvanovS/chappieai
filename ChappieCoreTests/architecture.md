<!--
  ChappieCoreTests/architecture.md

  ДОКУМЕНТ АРХИТЕКТУРЫ — CHAPPIECORETESTS

  Этот файл заменяет папку AI_Docs (architecture.md + project_map.md + semantic.json).
  Обновляй при каждом значимом изменении в тестах.
-->

# ChappieCoreTests — Архитектура тестового таргета

## 1. Назначение и структура

**ChappieCoreTests** — тестовый таргет в `Chappie.xcodeproj`, покрывающий бизнес-логику `ChappieCore`.

### Структура файлов

```
ChappieCoreTests/
├── architecture.md                     # Этот файл (заменяет папку AI_Docs/)
├── AITunnelModelsTests.swift           # Codable roundtrip, SSE-чанки, кэш-контроль
├── AppConfigTests.swift                # Значения конфига, Sendable, Codable
├── ChatHistoryManagerTests.swift       # Персистентность, изоляция воркспейсов
├── FileSystemManagerTests.swift        # Чтение/запись/удаление + Path Traversal защита
└── MemoryManagerTests.swift            # Сохранение, чтение, удаление, поиск
```

---

## 2. Как запускать тесты

**Через Xcode (основной способ):**
- Схема: `ChappieCoreTests`
- Горячая клавиша: `⌘+U`
- Тестплан: `ChappieCoreTests.xctestplan` (в корне проекта)

**Важно:** `run_tests` инструмент Чаппи запускает `swift test` внутри ChappieCore пакета,
а не Xcode тестплан. Для запуска тестов из этого таргета используй `⌘+U` в Xcode.

---

## 3. Архитектурные решения тестов

### Изоляция — обязательна

Каждый тест создаёт **временную директорию** через `FileManager.default.temporaryDirectory`
и удаляет её в `tearDown`. Это предотвращает:
- Загрязнение реальной памяти Чаппи (`~/Documents/Chappie/semantic.json`)
- Конфликты между параллельными тестами
- Зависимость от порядка выполнения тестов

### Запрет на scope: .global в тестах

**НЕЛЬЗЯ** использовать `scope: .global` в тестах `MemoryManager` — это пишет в
реальный `~/Documents/Chappie/semantic.json` и загрязняет рабочую память Чаппи.
Всегда использовать `scope: .project` с изолированным временным воркспейсом.

### Структура тестового воркспейса

`makeTempWorkspace()` создаёт полноценную структуру:
```
tempDir/
└── TestApp/
    └── TestApp.swift  ← суффикс App.swift → classifyTarget() → .appTarget
```
Это необходимо для корректной работы `MemoryManager.discoverTargets()` —
без Swift-файлов метод возвращает пустой массив таргетов.

### macOS /tmp симлинк

macOS `/tmp` — это симлинк на `/private/tmp`. `FileManager` возвращает пути через
`/private/tmp`, поэтому проверки путей в тестах используют `hasSuffix("filename")`
вместо точного совпадения строк.

### Единственный источник тестов

Файлы тестов живут **только** в `ChappieCoreTests/` (корень проекта).
В `ChappieCore/Tests/` тестов **нет** — `testTarget` убран из `Package.swift` намеренно,
чтобы не дублировать тесты и не создавать рассинхронизацию.

---

## 4. Описание тест-файлов

### `AITunnelModelsTests.swift`
- Codable roundtrip для всех моделей (`AIMessage`, `AITunnelRequest`, `AIStreamChunk` и др.)
- Проверка `AIMessageContent` полиморфного кодирования (строка vs блоки)
- Проверка `AICacheControl` сериализации
- Проверка `ChatMessage` с summary полем
- Проверка `AIStreamChunk` парсинга SSE-чанков

### `AppConfigTests.swift`
- Дефолтные значения конфига (`tokenBudget`, `recentFullMessages`, `summaryThreshold` и др.)
- Логическая согласованность: `recentFullMessages * summaryThreshold ≤ tokenBudget`
- Проверка `Sendable` и `Codable` conformance
- Проверка singleton `shared`

### `ChatHistoryManagerTests.swift`
- Сохранение и загрузка истории
- Добавление сообщений
- Очистка истории
- Персистентность между сессиями (через два разных экземпляра)
- Изоляция между разными workspace

### `FileSystemManagerTests.swift`
- Чтение существующего файла
- Запись и чтение файла
- Удаление файла
- **4 теста безопасности Path Traversal** (`../secret`, абсолютный путь и др.)
- Список файлов в директории (с `hasSuffix` проверками из-за `/private/tmp`)
- Чтение несуществующего файла → внятная ошибка

### `MemoryManagerTests.swift`
- Сохранение и загрузка записи (`scope: .project`)
- Поиск по типу
- Удаление записи
- Идемпотентность: два разных экземпляра с одним `workspaceURL` видят одни данные
- UUID-суффиксы для типов чтобы тесты не конфликтовали

---

## 📚 Changelog

| Date | Change | Author |
|------|--------|--------|
| 2026-05-24 | Initial creation (шаблон) | Chappie AI |
| 2026-06-XX | Полная переработка: реальное описание тестов | Chappie AI |
| 2026-06-XX | Рефакторинг: AI_Docs/ → один файл architecture.md | Chappie AI |
