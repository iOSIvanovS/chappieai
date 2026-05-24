# Карта проекта: ChappieCore (Library Target)

> **Обновлено:** 2026-05-28 — ТД-7 закрыт: стриминг токенов через SSE.
> **Тип:** Swift Package (Library Target)
> **Платформа:** macOS 15+, Swift 6 (Full Concurrency Checking)

---

## 🗺️ Реальная структура файлов

```text
ChappieCore/
├── Package.swift
├── AI_Docs/
│   ├── semantic.json
│   ├── architecture.md
│   └── project_map.md                  # Этот файл
└── Sources/ChappieCore/
    ├── ChappieCore.swift
    ├── Models/
    │   ├── AITunnelModels.swift        # + Streaming модели (ТД-7)
    │   ├── AppConfig.swift
    │   └── ChappieError.swift
    └── Services/
        ├── AITunnelClient.swift        # + streamRequest() (ТД-7)
        ├── AIOrchestrator.swift        # + onToken коллбэк (ТД-7)
        ├── ToolExecutionService.swift
        ├── FileSystemManager.swift
        ├── MemoryManager.swift
        └── ChatHistoryManager.swift
```

---

## 📝 Детальное описание файлов

### `AITunnelModels.swift` (обновлено ТД-7)
- **Изменение:** Добавлено поле `stream: Bool` в `AITunnelRequest`.
- **Новые типы для SSE:**

| Тип | Назначение |
|---|---|
| `AIStreamChunk` | Один чанк SSE-потока (id?, choices, usage?) |
| `AIStreamChoice` | Вариант внутри чанка (delta, finish_reason?) |
| `AIStreamDelta` | Дельта: content (текст) или tool_calls |
| `AIStreamToolCall` | Частичный tool_call (index, id?, type?, function?) |
| `AIStreamToolCallFunction` | Частичные данные функции (name?, arguments?) |

### `AITunnelClient.swift` (обновлено ТД-7)
- **Сохранён:** `sendRequest()` — без изменений, используется для tool-call шагов.
- **Добавлен:** `streamRequest()` → `(AsyncThrowingStream<String, Error>, getUsage)`.
- **Рефакторинг:** Общие части вынесены в `buildURLRequest()`, `performRequest()`, `validateHTTPResponse()`, `decodeResponse()`.
- **Добавлен:** `UsageBox` — приватный actor для передачи cost/balance из SSE-парсера.
- **Ключевой API:** `URLSession.bytes(for:)` — читает ответ построчно без ожидания полного тела.

### `AIOrchestrator.swift` (обновлено ТД-7)
- **Новый параметр:** `onToken: (@Sendable (String) -> Void)? = nil` в `process()`.
- **Стратегия "probe + stream":**
  - Probe: `sendRequest()` с инструментами → если tool_calls → выполняем.
  - Если probe вернул текст → `streamRequest()` без инструментов → токены в `onToken`.
- **Вынесен:** `executeToolCalls()` — общий метод для обеих веток (со стримингом и без).
- **Обратная совместимость:** `onToken = nil` → обычный путь без стриминга.

### Остальные файлы
- Без изменений в ТД-7.

---

## 🔌 Public API (обновлено ТД-7)

```swift
import ChappieCore

// Стриминговый запрос (новое в ТД-7)
let (stream, getUsage) = aiClient.streamRequest(
    systemPrompt: "...",
    chatHistory: history
)
for try await token in stream {
    print(token, terminator: "")
}
let usage = await getUsage()
print("Стоимость: \(usage.cost ?? 0) ₽")

// Агентный цикл со стримингом (новое в ТД-7)
let result = try await orchestrator.process(
    prompt: "Добавь тест",
    history: history,
    onToolCall: { toolName, path in print("🛠 \(toolName)") },
    onToken: { token in print(token, terminator: "") }
)
```

---

## 🚧 Known Issues & TODOs

| # | Описание | Статус |
|---|---|---|
| ТД-7 | Стриминг токенов | ✅ Закрыт |
| ТД-8 | Тестовый таргет в Package.swift | 🟡 Открыт |

---

## 📚 Changelog

| Date | Change | Author |
|------|--------|--------|
| 2026-05-21 | Initial creation | Chappie AI |
| 2026-05-27 | Полная переработка | Chappie AI |
| 2026-05-28 | ТД-7: streamRequest(), AIStreamChunk и др., onToken в process(), UsageBox | Chappie AI |
