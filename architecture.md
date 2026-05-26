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

---

## 6. Структура памяти — ФИНАЛЬНАЯ (IT-08 ✅, IT-09 ✅)

Три уровня памяти, все в SwiftData:

| Уровень | Хранилище | Инструмент |
|---|---|---|
| Глобальная | SwiftData MemoryEntity scope="global" | memorize(scope="global") |
| Проектная | SwiftData MemoryEntity scope="<projectId UUID>" | memorize(targetName="Chappie") |
| Тредовая | SwiftData MemoryEntity scope="<threadId UUID>" | memorize(scope="thread") |
| Документация таргетов | `<target>/architecture.md` | write_file вручную |

**АВТОМАТИЧЕСКОЕ ПОДМЕШИВАНИЕ В SYSTEM PROMPT (IT-09 ✅):**

Структура итогового промпта:
```
[базовый промпт — правила Чаппи]

---
## Memory Context

## Project Settings: Chappie          ← IT-09: права агента (первым!)
- Role: EXECUTOR
- Git: write [git_status, git_add, ...]
...

## Global Memory
## Project Memory: Chappie
## Thread Context
```

**ПРАВА АГЕНТА (IT-09 ✅):**
`ProjectSettings` хранится в `ProjectEntity.settingsJSON`.
Роль по умолчанию: `.advisor` (только чтение).
`ToolExecutionService.checkToolAccess()` проверяет права перед каждым инструментом.
`git_diff` НИКОГДА не разрешён — железный запрет в коде.

---

## 7. Группа 📚 Docs в Xcode Navigator

**Решение:** Группа `📚 Docs` добавлена в `project.pbxproj` как чисто навигационная PBXGroup.
- UUID корневой группы: `87DOCS0000000000000000000`
- Файлы: 5 PBXFileReference с UUID `87DOCS000000000000000000[1-5]`
- **НЕ участвует в сборке**, **НЕ копируется в бандл**

**УПРАВЛЕНИЕ ГРУППОЙ — ТОЛЬКО ВРУЧНУЮ** через `write_file` в `project.pbxproj`.
Автоматическая запись pbxproj была удалена (XcodeDocsGroupManager.swift) — повреждала файл проекта.

---

## 8. Зависания build_project и run_tests — РЕШЕНО (2025-07-11)

**Причина:** дедлок Pipe — xcodebuild ждёт чтения stdout, мы ждём завершения процесса.
**Решение:** читать stdout/stderr в отдельных DispatchQueue параллельно с waitUntilExit().
**Дополнительно:** явный `-destination "platform=macOS,arch=arm64"` для xcodebuild.

---

## 9. Техдолг

| ID | Проблема | Приоритет |
|----|----------|-----------|
| TD-01 | `build_project` зависал — РЕШЕНО (2025-07-11) | ✅ |
| TD-02 | Тесты `ChappieCoreTests` требуют ручного выбора таргета в Xcode перед ⌘+U. | Низкий |

---

## 10. Пайплайн работы в проекте

Зафиксирован по договорённости с пользователем:

1. `git commit` — сохранить checkpoint перед рефакторингом
2. Реализовать изменения
3. Добавить unit-тесты если нужно (для бизнес-логики, не тривиального UI)
4. `build_project`
5. `run_tests` (только после зелёного билда)
6. Фиксировать ошибки до консистентного состояния
7. `git commit`
8. Отчитаться пользователю

---

## 11. REFACTOR-THREADS + PROJECT SETTINGS

### Статус: ✅ ПОЛНОСТЬЮ ЗАВЕРШЁН (IT-01 → IT-09 ✅)

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
| IT-09 | ProjectSettings — роль агента и права доступа | ✅ ГОТОВО |

---

## 📚 Changelog

| Date | Change |
|------|--------|
| 2026-05-26 | IT-09 ✅: ProjectSettings (AgentRole, GitAccessLevel, TestsAccessLevel, ProjectLanguage), ProjectSettingsSheet UI, ToolExecutionService.checkToolAccess(), блок прав в system prompt |
| 2025-07-XX | IT-08 ✅: ActiveMemoryContext, UUID-based scope, resolveScope(), syncActiveMemoryContext() |
| 2025-07-XX | IT-07 ГОТОВО: add/remove/list_thread_projects инструменты |
| 2025-07-XX | IT-06 ГОТОВО: ProjectChipsView, ChappieViewModel addProject/removeProject |
| 2025-07-XX | IT-05 ГОТОВО: ThreadListView, ThreadRowView, SidebarView с тредами |
| 2025-07-XX | IT-04 ГОТОВО: MigrationService (chat_history.json + semantic.json → SwiftData) |
| 2025-07-XX | IT-03 ГОТОВО: MemoryStore (SwiftData CRUD), buildSystemPrompt() с трёхуровневой памятью |
| 2025-07-XX | IT-02 ГОТОВО: динамический AppConfig |
| 2025-07-XX | IT-01 ГОТОВО: SwiftData модели |
| 2025-07-11 | РЕШЕНО TD-01: исправлен дедлок Pipe в BuildTools.swift |
| 2025-07-10 | КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: удалён XcodeDocsGroupManager |
