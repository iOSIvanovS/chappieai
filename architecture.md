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
| @Observable | Observation framework | ViewModel |
| Actors | Swift Concurrency | ChappieCore сервисы |
| Claude Sonnet 4.6 | claude-sonnet-4.6 | AI модель |
| AITunnel API | OpenAI-совместимый | Прокси к Anthropic |
| Unix Domain Sockets | POSIX | IPC с ChappieMCP |
| Keychain | Security framework | Хранение API-ключа |

---

## 5. История чата (TD-03)

**Путь:** `<workspaceURL>/chat_history.json` (прямо в корне проекта)

Управляется `ChatHistoryManager` в ChappieCore.

**Ключевые решения:**
- Файл лежит в КОРНЕ воркспейса (не в AI_Docs/ — папка упразднена).
- Автоматическое подрезание до 100 сообщений при каждом сохранении.
- 100 сообщений = ~20-50 диалоговых пар, достаточно для работы.
- Оркестратор всё равно берёт только последние 12 (maxMessagesInContext).

**ВАЖНО:** При рефакторинге — путь нельзя менять без обновления `ChatHistoryManager.swift`.

---

## 6. Структура памяти (TD-03)

Три уровня памяти:

| Уровень | Файл | Управляется |
|---|---|---|
| Глобальная (кросс-проектная) | `~/Documents/Chappie/semantic.json` | `MemoryManager` (scope: global) |
| Локальная (таргет) | `<target>/architecture.md` | Чаппи вручную через write_file |
| История чата | `<workspaceURL>/chat_history.json` | `ChatHistoryManager` |

Папки `AI_Docs/` во всех таргетах **упразднены** — они были избыточны.
Каждый таргет имеет только `architecture.md` в своём корне.

---

## 📚 Changelog

| Date | Change |
|------|--------|
| 2025-06 | TD-03: рефакторинг AI_Docs/ → один файл architecture.md на таргет; chat_history.json переехал в корень воркспейса; подрезание до 100 сообщений |
| 2025-06 | Initial creation: рефакторинг AI_Docs/ → один файл architecture.md |
