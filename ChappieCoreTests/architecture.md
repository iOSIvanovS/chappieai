<!--
  ChappieCoreTests/architecture.md

  ЕДИНЫЙ ДОКУМЕНТ АРХИТЕКТУРЫ — CHAPPICORETESTS

  Этот файл заменяет папку AI_Docs (architecture.md + project_map.md + semantic.json).
  Обновляй при каждом значимом изменении тестовой архитектуры.

  Последнее обновление: исправлены xcscheme файлы — устранён (unknown) 0 Excluded Tests и закрытие окна
-->

# ChappieCoreTests — Архитектура тестового таргета

## 1. Назначение

**ChappieCoreTests** — Unit Test Bundle для тестирования бизнес-логики `ChappieCore`.
Запускается через Xcode тестплан `ChappieCoreTests.xctestplan` в корне проекта.

### Ключевые принципы

- **Изоляция:** каждый тест создаёт собственную временную директорию через `FileManager.default.temporaryDirectory`
- **Без глобального состояния:** `scope: .global` в тестах — запрещён, только `scope: .project` с изолированным воркспейсом
- **UUID-суффиксы:** типы и ключи содержат UUID чтобы тесты не конфликтовали через общие файлы
- **Swift Testing framework:** используем `import Testing`, `@Suite`, `@Test`, `#expect` (не XCTest)

---

## 2. Структура файлов

```
ChappieCoreTests/
├── architecture.md                     # Этот файл
├── ChappieCoreTests.xctestplan         # В корне проекта (не здесь!)
├── AppConfigTests.swift                # Тесты конфигурации
├── AITunnelModelsTests.swift           # Тесты Codable-моделей
├── ChatHistoryManagerTests.swift       # Тесты менеджера истории чата
├── FileSystemManagerTests.swift        # Тесты файловой системы + безопасности
└── MemoryManagerTests.swift            # Тесты семантической памяти
```

### ВАЖНО: Единственный источник тестов

Тесты живут ТОЛЬКО в `ChappieCoreTests/` и запускаются через `ChappieCoreTests.xctestplan`.

Папка `ChappieCore/Tests/ChappieCoreTests/` — **не используется**. В `ChappieCore/Package.swift`
намеренно нет `testTarget`, чтобы избежать дублирования и рассинхронизации.

---

## 3. Правила xcscheme (КРИТИЧЕСКИ ВАЖНО — не нарушать!)

### Проблемы которые были и как они решены:

#### Проблема 1: `(unknown) 0 Excluded Tests` в Test Navigator
**Причина:** В `Chappie.xcscheme` был пустой `<TestAction>` блок. Xcode регистрирует
ЛЮБОЙ TestAction в Test Navigator — даже пустой — как анонимный контейнер "(unknown)".

**Решение:** Полностью удалён `<TestAction>` из `Chappie.xcscheme`. Теперь там только
`BuildAction` и `LaunchAction` для запуска приложения.

#### Проблема 2: При ⌘+U закрывалось окно Чаппи
**Причина:** В `ChappieCoreTests.xcscheme` в `<LaunchAction>` был `<BuildableProductRunnable>`
указывающий на `Chappie.app`. Xcode перед запуском тестов убивал процесс этого приложения.

**Решение:** `<LaunchAction>` в `ChappieCoreTests.xcscheme` теперь **без** `<BuildableProductRunnable>`.
Пустой LaunchAction = "не запускай и не убивай никакое приложение". Тест-раннер xctest
запускается в своём процессе, не трогая работающий Chappie.app.

### Правильный workflow запуска тестов:
1. Переключить схему в тулбаре Xcode на **"ChappieCoreTests"**
2. Нажать **⌘+U** — тесты запустятся, окно Чаппи останется открытым
3. Переключить схему обратно на **"Chappie"** для обычной работы

---

## 4. Тестовые файлы

### `AppConfigTests.swift`
Тестирует структуру `AppConfig` — единственный источник истины для параметров системы.

| Тест | Что проверяет |
|------|--------------|
| `defaultValues` | Все дефолтные значения в разумных диапазонах |
| `tokenBudget` | `tokenBudget > 0` |
| `recentFullMessages` | `recentFullMessages > 0` |
| `summaryThreshold` | `summaryThreshold > 0` |
| `logicalConsistency` | `recentFullMessages * summaryThreshold <= tokenBudget` |
| `sharedIsSingleton` | `AppConfig.shared === AppConfig.shared` |

### `AITunnelModelsTests.swift`
Тестирует Codable-модели для работы с API AITunnel.

| Тест | Что проверяет |
|------|--------------|
| `aIMessageEncodingDecoding` | Roundtrip AIMessage через JSON |
| `aIMessageContentText` | `.text` кейс AIMessageContent |
| `aIMessageContentBlocks` | `.blocks` кейс с cache_control |
| `aICacheControl` | Сериализация AICacheControl |
| `aIStreamChunkDecoding` | Парсинг SSE-чанков |
| `chatMessageWithSummary` | ChatMessage с полем summary |
| `aITunnelRequestStream` | AITunnelRequest с stream: true |

### `ChatHistoryManagerTests.swift`
Тестирует сохранение и загрузку истории чата.

| Тест | Что проверяет |
|------|--------------|
| `loadEmptyHistoryOnFirstRun` | Пустой массив при отсутствии файла |
| `saveAndLoadMessages` | Roundtrip сохранение/загрузка |
| `appendMessages` | Добавление сообщений к существующим |
| `clearHistory` | Очистка истории |
| `persistenceAcrossSessions` | Данные сохраняются между экземплярами |
| `workspaceIsolation` | Разные воркспейсы изолированы |

### `FileSystemManagerTests.swift`
Тестирует работу с файловой системой и защиту от Path Traversal.

| Тест | Что проверяет |
|------|--------------|
| `readExistingFile` | Чтение существующего файла |
| `writeAndReadFile` | Запись и чтение файла |
| `deleteFile` | Удаление файла |
| `pathTraversalProtection` | `../secret` → ошибка безопасности |
| `listFilesReturnsAllFiles` | Список файлов в директории |
| `readNonExistentFile` | Понятная ошибка при отсутствии файла |
| `writeToSubdirectory` | Запись с автосозданием подпапки |

**Особенность macOS:** `/tmp` — симлинк на `/private/tmp`. Поэтому проверки путей
используют `hasSuffix` вместо точного совпадения.

### `MemoryManagerTests.swift`
Тестирует семантическую память ИИ-ассистента.

| Тест | Что проверяет |
|------|--------------|
| `saveAndLoadRecord` | Сохранение и загрузка записи |
| `deleteRecord` | Удаление записи |
| `searchByType` | Поиск по типу записи |
| `searchReturnsEmpty` | Поиск без результатов |
| `emptyStorageRead` | Чтение из пустого хранилища |
| `multipleRecords` | Несколько записей разных типов |
| `scopeIsolation` | Изоляция между scope: .project таргетами |
| `initializationIsIdempotent` | Повторная инициализация не затирает данные |

**Изоляция тестов:** `makeTempWorkspace()` создаёт структуру:
```
tempDir/
└── TestApp/
    └── TestApp.swift  ← суффикс App.swift → classifyTarget() → .appTarget
```
Это обеспечивает корректное обнаружение таргета без записи в реальную память Чаппи.

---

## 5. Правила написания тестов

### Обязательные правила

1. **Никогда не использовать `scope: .global`** — пишет в реальную `~/Documents/Chappie/semantic.json`
2. **UUID-суффиксы для типов** — `"testType_\(UUID().uuidString)"` чтобы тесты не конфликтовали
3. **Временная директория** — всегда через `FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)`
4. **Структура воркспейса** — создавать через `makeTempWorkspace()` с файлом `*App.swift`

### Запрещено

- `XCTest` — используем только Swift Testing (`import Testing`)
- `scope: .global` в тестах MemoryManager
- Хардкоженные пути к реальным файлам проекта

---

## 6. Запуск тестов

### Через Xcode (основной способ)
1. Переключить схему на **"ChappieCoreTests"** в тулбаре
2. Нажать **⌘+U**

### ⚠️ ВАЖНО: run_tests(target:) НЕ РАБОТАЕТ для этого таргета

Инструмент `run_tests(target: "ChappieCoreTests")` вызывает `swift test` в `ChappieCore/`
(Swift Package), а не `xcodebuild test`. Поскольку в `Package.swift` намеренно нет
`testTarget` — инструмент всегда возвращает "no tests found".

**Это не баг тестов, это ограничение MCP-инструмента.**
Тесты работают корректно через Xcode (⌘+U при активной схеме ChappieCoreTests).

---

## 7. Build Settings (исправлено 2026-05-25)

Таргет `ChappieCoreTests` в `project.pbxproj` должен иметь:

```
SDKROOT = macosx;                    // ← было watchos (БАГИ!)
MACOSX_DEPLOYMENT_TARGET = 26.5;     // ← было WATCHOS_DEPLOYMENT_TARGET
SUPPORTED_PLATFORMS = macosx;
SWIFT_VERSION = 6.0;                 // ← было 5.0
```

**Почему это важно:** при `SDKROOT = watchos` xcodebuild не мог найти тесты при первом
запуске — Xcode видел таргет как watchOS и не мог его запустить на Mac без симулятора.

---

## 📚 Changelog

| Date | Change | Author |
|------|--------|--------|
| 2026-05-24 | Initial creation (шаблон) | Chappie AI |
| 2026-05-24 | Полное наполнение: описание всех тестов, правила изоляции | Chappie AI |
| 2026-05-24 | Рефакторинг: AI_Docs/ → один файл architecture.md | Chappie AI |
| 2026-05-25 | Исправлен SDKROOT watchos→macosx, SWIFT_VERSION 5.0→6.0 | Chappie AI |
| 2026-05-25 | Задокументировано ограничение run_tests(target:) | Chappie AI |
| 2026-05-25 | Исправлены xcscheme: удалён TestAction из Chappie.xcscheme, убран BuildableProductRunnable из LaunchAction в ChappieCoreTests.xcscheme | Chappie AI |
