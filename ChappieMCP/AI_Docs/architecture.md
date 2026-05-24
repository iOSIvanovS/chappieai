<!--
  ChappieMCP/AI_Docs/architecture.md
  Архитектура ChappieMCP — локального MCP-сервера инструментов.
  Создан: 2026-05-29
-->

# ChappieMCP — Архитектура

## 1. Назначение

ChappieMCP — локальный HTTP-сервер, предоставляющий ИИ-агенту Чаппи инструменты
для работы с git и xcodebuild. Запускается как отдельный процесс на Mac разработчика.

**Почему отдельный процесс:**
- Chappie.app работает в macOS Sandbox — не может запускать произвольные процессы
- Независимость: сервер перезапускается без перезапуска приложения
- Разделение привилегий: приложение — минимальные права, сервер — полный доступ

## 2. Структура файлов

```
ChappieMCP/
├── Package.swift                         — Swift CLI executable, macOS 13+
├── com.chappie.mcp.plist                 — LaunchAgent для автостарта
├── AI_Docs/
│   └── architecture.md                   — этот файл
└── Sources/ChappieMCP/
    ├── main.swift                         — точка входа, запуск сервера
    ├── Server/
    │   ├── MCPHTTPServer.swift            — HTTP-сервер + ToolDispatcher
    │   └── HealthEndpoint.swift           — GET /health endpoint
    └── Tools/
        ├── GitTools.swift                 — git инструменты
        └── BuildTools.swift               — xcodebuild/swift test инструменты
```

## 3. Транспортный протокол

**HTTP/1.1 localhost:7771**

```
GET  /health  → {"status":"ok","version":"1.0.0","uptime":42.0,"tools":[...]}
POST /tool    → Body: {"tool":"git_status","args":{}}
              ← {"result":"...", "error":null}
```

Почему HTTP а не stdio/XPC/Unix socket:
- Sandbox Chappie.app разрешает HTTP к localhost
- Легко дебажить через curl
- Независимость от жизненного цикла приложения

## 4. Инструменты

### Git (GitTools.swift)
| Инструмент | Команда | Аргументы |
|---|---|---|
| `git_status` | `git status --short --branch` | — |
| `git_diff` | `git diff [--staged]` | `staged: "true/false"` |
| `git_add` | `git add <paths>` | `paths: "."` |
| `git_commit` | `git commit -m <message>` | `message: "..."` |
| `git_log` | `git log --oneline --graph -N` | `count: "10"` |
| `git_reset` | `git reset HEAD` | — |

### Build (BuildTools.swift)
| Инструмент | Команда | Аргументы |
|---|---|---|
| `build_project` | `xcodebuild -project Chappie.xcodeproj -scheme Chappie build` | — |
| `run_tests` | `xcodebuild test` или `swift test` | `target: "ChappieCoreTests"` |
| `read_build_log` | Читает `.build_log.txt` | — |

**Лог сборки:** сохраняется в `/Volumes/Хранилище/Работа/Chappie/.build_log.txt`

## 5. Интеграция с ChappieCore

```
Chappie.app
  └── ToolExecutionService (actor)
        ├── [существующие: list_files, read_file, write_file, ...]
        └── MCPToolBridge (actor)         ← новый сервис
              │ HTTP POST /tool
              ▼
        ChappieMCP (отдельный процесс)
              ├── GitTools
              └── BuildTools
```

**MCPToolBridge** (ChappieCore/Services/MCPToolBridge.swift):
- Проверяет доступность сервера через GET /health (таймаут 2с)
- Если недоступен — возвращает инструкцию по запуску
- Таймаут для build/test запросов: 600 секунд (10 минут)

## 6. Установка и запуск

### Ручной запуск (разработка)
```bash
swift run --package-path /Volumes/Хранилище/Работа/Chappie/ChappieMCP \
  ChappieMCP /Volumes/Хранилище/Работа/Chappie
```

### Автостарт через LaunchAgent
```bash
cp ChappieMCP/com.chappie.mcp.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.chappie.mcp.plist
```

### Проверка
```bash
curl http://localhost:7771/health
curl -X POST http://localhost:7771/tool \
  -H "Content-Type: application/json" \
  -d '{"tool":"git_status","args":{}}'
```

## 7. Агентный цикл с MCP (целевое состояние)

```
Чаппи получает задачу "отрефактори X, протестируй, закоммить"
  │
  ├── read_file(X)              — читает код
  ├── write_file(X)             — пишет рефакторинг
  ├── build_project()           — проверяет компиляцию
  │     ├── ❌ ошибки → read_build_log() → fix → build_project() снова
  │     └── ✅ успех → продолжаем
  ├── run_tests("ChappieCoreTests")  — запускает тесты
  │     ├── ❌ падают → анализирует → fix → run_tests() снова
  │     └── ✅ проходят → продолжаем
  ├── git_add(".")              — staging
  ├── git_status()              — проверяет что staging правильный
  └── git_commit("feat: ...")   — коммит
```

## 8. Технический долг

| # | Описание | Приоритет |
|---|---|---|
| MCP-1 | Добавить `git_push` инструмент | 🟡 |
| MCP-2 | Streaming вывода xcodebuild (сейчас ждём завершения) | 🟡 |
| MCP-3 | Аутентификация запросов к серверу (сейчас без auth) | 🟢 |
| MCP-4 | Скомпилированный бинарник вместо swift run (быстрый старт) | 🟡 |
