<!--
  ChappieCore/architecture.md

  ЕДИНЫЙ ДОКУМЕНТ АРХИТЕКТУРЫ — CHAPPIECORE (БИЗНЕС-ЛОГИКА)

  Этот файл — единственный источник архитектурной документации для ChappieCore.
  Обновляй при каждом значимом архитектурном изменении.
-->

# ChappieCore — Архитектура библиотеки

## 1. Назначение

**ChappieCore** — Swift Package Library, содержащая всю бизнес-логику Чаппи.
UI-таргет `Chappie.app` — тонкая оболочка, ChappieCore делает всю реальную работу.

### Принцип изоляции

- **Никакого UIKit/SwiftUI** в ChappieCore — только Foundation и системные фреймворки.
- **Все сервисы — акторы** (`actor`) для безопасного конкурентного доступа в Swift 6.
- **Публичный API** — только то, что нужно UI-таргету. Детали реализации — `internal`.

---

## 2. Структура файлов

```
ChappieCore/Sources/ChappieCore/
├── ChappieCore.swift                   # Публичный фасад библиотеки
├── Models/
│   ├── AITunnelModels.swift            # AIMessage, AIToolCall, AIStreamResult и т.д.
│   ├── AppConfig.swift                 # Конфигурация: токены, лимиты, модель
│   └── ChappieError.swift              # Типизированные ошибки
└── Services/
    ├── AIOrchestrator.swift            # Агентный цикл: запрос → инструменты → ответ
    ├── AITunnelClient.swift            # HTTP-клиент к AITunnel API (стриминг SSE)
    ├── ChatHistoryManager.swift        # Сохранение/загрузка истории чата
    ├── FileSystemManager.swift         # Чтение/запись файлов (с защитой Path Traversal)
    ├── MCPToolBridge.swift             # Unix Domain Socket клиент к ChappieMCP
    ├── MemoryManager.swift             # Семантическая память + инициализация воркспейса
    ├── ToolExecutionService.swift      # Диспетчер вызовов инструментов от модели
    └── XcodeDocsGroupManager.swift     # Синхронизация группы "📚 Docs" в pbxproj
```

---

## 3. Ключевые сервисы

### AIOrchestrator
Главный управляющий компонент. Реализует агентный цикл:
`запрос → streamRequestWithTools → tool_calls? → выполнить → повторить → финальный ответ`

**Ключевые решения:**
- Единый стриминговый цикл (не два запроса probe+stream)
- Умное контекстное окно: tokenBudget + maxMessagesInContext
- Сжатие старых сообщений через `<summary>` тег
- Защита от зацикливания: `executedToolSignatures`

### MemoryManager
Управляет файловой структурой памяти воркспейса.

**Что делает при инициализации:**
1. Создаёт `~/Documents/Chappie/semantic.json` (глобальная память)
2. Сканирует таргеты воркспейса (папки без расширения в корне)
3. Создаёт `architecture.md` для новых таргетов (шаблон)
4. Удаляет устаревшие `AI_Docs/` и `semantic.json` в таргетах (миграция)
5. **Синхронизирует группу "📚 Docs" в pbxproj** через `XcodeDocsGroupManager`

### XcodeDocsGroupManager
Автоматически поддерживает актуальность группы "📚 Docs" в Xcode Navigator.

**Зачем:** При добавлении нового таргета `MemoryManager` создаёт `architecture.md`,
но Xcode не знает об этом файле. `XcodeDocsGroupManager` обновляет `project.pbxproj`
так, чтобы ссылка на новый файл сразу появилась в Navigator.

**Архитектурное решение — текстовое редактирование pbxproj:**
- pbxproj это OpenStep plist — НЕ JSON, НЕ XML. Стандартными парсерами не разобрать.
- Используем точечное текстовое редактирование по уникальным маркерам `87DOCS...`
- Наши ID имеют префикс `87DOCS` — не пересекается с нативными hex-ID Xcode
- Идемпотентен: если состояние актуально — pbxproj не перезаписывается

**Уникальные ID объектов в pbxproj:**
```
87DOCS0000000000000000000  — группа "📚 Docs" (контейнер)
87DOCS0001000000000000001  — architecture.md (корень воркспейса)
87DOCS0002000000000000002  — architecture.md (первый таргет, App)
87DOCS0003000000000000003  — architecture.md (второй таргет)
...и т.д.
```

**Два режима работы:**
- `replaceExistingDocsBlocks` — маркеры уже есть, обновляем (штатный режим)
- `insertDocsBlocks` — маркеров нет, первичная вставка (новый проект)

### FileSystemManager
"Руки" ИИ-агента в файловой системе. Защита от Path Traversal (CWE-22):
`validateAndResolvePath()` → `standardized` + `resolvingSymlinksInPath()` → `hasPrefix(workspacePath)`

### MCPToolBridge
Unix Domain Socket клиент. Отправляет JSON-запросы к `ChappieMCP` хелперу.
Сокет: `/tmp/com.chappie.mcp.sock`

---

## 4. Структура памяти

| Уровень | Файл | Управляется |
|---------|------|-------------|
| Глобальная | `~/Documents/Chappie/semantic.json` | `MemoryManager` |
| Документация таргета | `<Target>/architecture.md` | Чаппи вручную через `write_file` |
| История чата | `<WorkspaceRoot>/chat_history.json` | `ChatHistoryManager` |
| Xcode Navigator | `project.pbxproj` → группа `📚 Docs` | `XcodeDocsGroupManager` |

---

## 5. Агентный цикл (детали)

```
process(prompt:history:onToolCall:onToken:)
    ↓
buildContextWindow()          ← дедупликация + tokenBudget + maxMessages
    ↓
while stepCount < maxSteps:
    streamRequestWithTools()  ← ОДИН запрос, стриминг SSE
        ↓ onToken             ← каждый токен → UI
    if toolCalls:
        executeToolCalls()    ← ToolExecutionService.execute()
        continue
    else:
        return finalResponse  ← текст уже в UI через onToken
```

---

## 6. Контекстное окно (AppConfig параметры)

| Параметр | Значение | Назначение |
|----------|----------|------------|
| `tokenBudget` | 6,000 | Мягкий лимит токенов |
| `maxMessagesInContext` | 12 | Жёсткий лимит сообщений |
| `recentFullMessages` | 3 | Последние N — всегда полностью |
| `summaryThreshold` | 400 | Длиннее → заменить на summary |
| `maxOrchestratorSteps` | 20 | Защита от бесконечного цикла |

---

## 7. Технический долг

| # | Описание | Приоритет | Статус |
|---|----------|-----------|--------|
| ТД-TEST | Unit-тесты для XcodeDocsGroupManager | 🟡 | 🔲 Открыт |

---

## 📚 Changelog

| Date | Change |
|------|--------|
| 2026-05-21 | Initial creation |
| 2026-06-XX | Рефакторинг: AI_Docs/ → один файл architecture.md |
| 2026-06-XX | XcodeDocsGroupManager: автосинхронизация группы 📚 Docs в pbxproj |
