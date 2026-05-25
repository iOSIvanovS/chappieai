<!--
  ChappieMCP/architecture.md

  ДОКУМЕНТ АРХИТЕКТУРЫ — CHAPPIEMCP

  Этот файл заменяет папку AI_Docs (architecture.md + project_map.md + semantic.json).
  Обновляй при каждом значимом изменении.
  Создан: 2026-05-29
-->

# ChappieMCP — Архитектура

## 1. Назначение

ChappieMCP — локальный хелпер-процесс, запускаемый `Chappie.app` как дочерний процесс.
Предоставляет ИИ-агенту Чаппи инструменты для работы с git и xcodebuild.

**Почему отдельный процесс:**
- Chappie.app (без Sandbox) может запускать дочерние процессы
- Независимость: хелпер перезапускается без перезапуска приложения
- Разделение ответственности: UI-слой не знает о git/xcodebuild напрямую

**Почему встроен в Chappie.app (а не отдельный пакет):**
- Пользователь просто скачивает `.app` — всё внутри
- Никакого терминала, никаких отдельных папок
- Xcode собирает хелпер как отдельный таргет и копирует в `Contents/Helpers/`

---

## 2. Структура файлов

```
ChappieMCP/                            — Xcode таргет (Command Line Tool) внутри Chappie.xcodeproj
├── architecture.md                    — этот файл (заменяет папку AI_Docs/)
├── main.swift                         — точка входа, читает argv, запускает MCPUnixServer
├── MCPHTTPServer.swift                — Unix Domain Socket сервер + ToolDispatcher
├── GitTools.swift                     — git инструменты
└── BuildTools.swift                   — xcodebuild/swift test инструменты

Расположение в .app:
Chappie.app/
└── Contents/
    ├── MacOS/
    │   └── Chappie          ← основной бинарник
    └── Helpers/
        └── ChappieMCP       ← этот хелпер (Copy Files Build Phase)
```

---

## 3. Транспортный протокол

**Unix Domain Socket** — `/tmp/com.chappie.mcp.sock`

### Протокол: length-prefixed framing

```
Запрос:
  [4 байта: UInt32 big-endian длина JSON] [JSON данные]
  JSON: {"tool": "git_status", "args": {}}

Ответ:
  [4 байта: UInt32 big-endian длина JSON] [JSON данные]
  JSON: {"result": "...", "error": null}
```

**Почему Unix Domain Socket а не TCP:**
- App Sandbox (даже отключённый) имеет особенности с TCP серверами в дочерних процессах
- UDS через `/tmp/` надёжно работает без дополнительных entitlements
- Быстрее TCP для локального IPC

### Запуск хелпера

```
MCPHelperLauncher.shared.launch(workspacePath: url.path)
    ↓
Process.run(
    executableURL: Bundle.main.url(forAuxiliaryExecutable: "ChappieMCP"),
    arguments: [workspacePath, socketPath]
)
```

`argv[1]` = путь к воркспейсу (рабочий каталог для git/xcodebuild)
`argv[2]` = путь к сокету (обычно `/tmp/com.chappie.mcp.sock`)

---

## 4. Инструменты

### Git (GitTools.swift)

| Инструмент | Команда | Аргументы |
|---|---|---|
| `git_status` | `git status --short --branch` | — |
| `git_add` | `git add <paths>` | `paths: "."` |
| `git_commit` | `git commit -m <message>` | `message: "..."` |
| `git_log` | `git log --oneline --graph -N` | `count: "10"` |
| `git_reset` | `git reset HEAD` | — |

**ЗАПРЕЩЁННЫЕ инструменты:**
- `git_diff` — ЗАПРЕЩЁН НАВСЕГДА. Загружает весь diff в контекст ИИ → стоит сотни рублей.

**Важно:** все git-команды запускаются с переменными окружения:
```
GIT_PAGER=cat           — отключает pager (less), иначе headless процесс зависает
GIT_TERMINAL_PROMPT=0   — запрещает запрашивать пароль через TTY
GIT_CONFIG_NOSYSTEM=1   — игнорирует /etc/gitconfig с потенциально кастомным pager
TERM=dumb               — сигнализирует что TTY нет
```

### Build (BuildTools.swift)

| Инструмент | Команда | Аргументы |
|---|---|---|
| `build_project` | `xcodebuild -project Chappie.xcodeproj -scheme Chappie build` | — |
| `run_tests` | `xcodebuild test` или `swift test` | `target: "ChappieCoreTests"` |
| `read_build_log` | Читает `.build_log.txt` | — |

**Лог сборки:** сохраняется в `<workspacePath>/.build_log.txt`

---

## 5. Интеграция с ChappieCore

```
Chappie.app
  └── ToolExecutionService (actor)
        ├── [существующие: list_files, read_file, write_file, ...]
        └── MCPToolBridge (actor)         ← сервис в ChappieCore
              │ Unix Domain Socket
              ▼
        ChappieMCP (дочерний процесс)
              ├── GitTools
              └── BuildTools
```

**MCPToolBridge** (`ChappieCore/Services/MCPToolBridge.swift`):
- Подключается к сокету при каждом вызове инструмента (не держит постоянное соединение)
- Таймаут для build/test запросов: 600 секунд (10 минут)
- Если хелпер не запущен — возвращает понятное сообщение вместо зависания

---

## 6. Обязательный пайплайн изменений

Перед каждым изменением кода Чаппи ОБЯЗАН следовать этому порядку:

```
1. git_status              → проверить нет ли незакоммиченных изменений
2. git_add + git_commit    → CHECKPOINT коммит (точка отката)
3. write_file              → внести изменения
4. build_project           → компиляция (если упала — чинить, не идти дальше)
5. run_tests               → тесты (только если сборка прошла)
6. git_add + git_commit    → RESULT коммит (только если всё зелёное)
7. Сообщить пользователю   → "можно жать треугольник в Xcode"
```

**При падении build или tests** — предложить откат к checkpoint коммиту.

---

## 7. Технический долг

| # | Описание | Приоритет |
|---|---|---|
| MCP-1 | Добавить `git_push` инструмент | 🟡 |
| MCP-2 | Streaming вывода xcodebuild (сейчас ждём завершения) | 🟡 |
| MCP-3 | Аутентификация запросов к серверу (сейчас без auth) | 🟢 |

---

## 📚 Changelog

| Date | Change | Author |
|------|--------|--------|
| 2026-05-29 | Initial creation | Chappie AI |
| 2026-06-XX | Переход с TCP на Unix Domain Socket | Chappie AI |
| 2026-06-XX | Исправление зависания git_diff — GIT_PAGER=cat | Chappie AI |
| 2026-06-XX | Рефакторинг: AI_Docs/ → один файл architecture.md | Chappie AI |
