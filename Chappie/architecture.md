<!--
  Chappie/architecture.md

  ЕДИНЫЙ ДОКУМЕНТ АРХИТЕКТУРЫ — UI ТАРГЕТ (Chappie.app)

  Этот файл — единственный источник архитектурной документации для UI-слоя.
  Обновляй при каждом значимом архитектурном изменении.
-->

# Chappie.app — Архитектура UI-слоя

## 1. Назначение

**Chappie.app** — тонкая SwiftUI-оболочка над ChappieCore.
Вся бизнес-логика живёт в ChappieCore. UI-таргет отвечает только за:
- Отображение данных из ViewModel
- Обработку пользовательского ввода
- Навигацию и анимации
- Запуск ChappieMCP хелпера

---

## 2. Структура файлов

```
Chappie/
├── ChappieApp.swift                    # @main, ModelContainer, onAppear
├── ContentView.swift                   # Дирижёр: собирает компоненты, управляет sheets
├── ChappieViewModel.swift              # @Observable @MainActor ViewModel
├── MCPHelperLauncher.swift             # Запуск ChappieMCP дочернего процесса
├── Models/
│   └── ChatMessage.swift               # UI-модель сообщения (enum с .message/.toolCall)
├── Settings/
│   ├── SettingsView.swift              # Sheet настроек приложения (API-ключ)
│   ├── SettingsManager.swift           # UserDefaults + Keychain для API-ключа
│   └── KeychainManager.swift           # Keychain wrapper
└── Views/
    ├── Chat/
    │   ├── ChatScrollView.swift         # Лента сообщений
    │   ├── MessageBubbleView.swift      # Пузырь одного сообщения
    │   ├── MarkdownTextView.swift       # Рендер Markdown в NSAttributedString
    │   ├── StatusBarView.swift          # Строка статуса (текущий инструмент)
    │   ├── ProjectChipsView.swift       # [IT-06, IT-09] Чипы проектов + тап → настройки
    │   └── ProjectSettingsSheet.swift  # [IT-09] Sheet настроек проекта
    ├── Input/
    │   └── InputBarView.swift           # Поле ввода + кнопка отправки
    ├── Sidebar/
    │   ├── SidebarView.swift            # Боковая панель (контейнер)
    │   ├── ThreadListView.swift         # Список тредов
    │   └── ThreadRowView.swift          # Строка одного треда
    └── Toolbar/
        └── ToolbarContent.swift         # Тулбар: баланс + настройки
```

---

## 3. ChappieViewModel

`@Observable @MainActor final class ChappieViewModel`

### Ключевые свойства

| Свойство | Тип | Назначение |
|----------|-----|------------|
| `threads` | `[ThreadMetadata]` | Список всех тредов для боковой панели |
| `activeThread` | `ThreadMetadata?` | Активный тред |
| `activeProjects` | `[ProjectMetadata]` | Проекты активного треда |
| `activeMemoryContext` | `MemoryContext` | Контекст для system prompt (IT-09: с settings) |
| `messages` | `[ChatMessage]` | Полная история (UI + legacy) |
| `isThinking` | `Bool` | Индикатор загрузки |
| `streamingText` | `String` | Текущий стриминговый ответ |
| `runningCost` | `Double` | Накопленная стоимость запроса |

### Ключевые методы

| Метод | Назначение |
|-------|------------|
| `setModelContainer(_:)` | Подключает SwiftData, регистрирует обработчики |
| `selectThread(_:)` | Загружает тред + проекты + синхронизирует контекст |
| `addProject(url:)` | Добавляет проект через NSOpenPanel bookmark |
| `removeProject(id:)` | Убирает проект из треда |
| `updateProjectSettings(_:forProjectId:)` | **[IT-09]** Сохраняет настройки проекта |
| `buildAndSyncMemoryContext()` | Собирает MemoryContext с settings (IT-09) |
| `syncActiveMemoryContext()` | Синхронизирует ToolExecutionService (context + settings) |
| `send(prompt:)` | Отправляет запрос в AIOrchestrator |

### Поток данных при смене треда

```
selectThread()
  → loadProjectsForThread()      ← ProjectStore → activeProjects
  → buildAndSyncMemoryContext()  ← activeProjects → MemoryContext (с settings IT-09)
  → syncActiveMemoryContext()    ← ToolExecutionService.setActiveMemoryContext()
                                 ← ToolExecutionService.setProjectSettings() (IT-09)
```

---

## 4. IT-09: ProjectSettingsSheet

**Открывается:** тап на чип проекта в ProjectChipsView → `onOpenSettings(UUID)` → `ContentView.selectedProjectForSettings`

**Паттерн:** "тупой компонент" — не знает о SwiftData.
- Принимает `ProjectMetadata` и `onSave: (ProjectSettings) -> Void`
- Редактирует `@State draft: ProjectSettings` (копия, не оригинал)
- При "Сохранить" → `onSave(draft)` → `viewModel.updateProjectSettings()`

**Логика разблокировки:**
```
.advisor → только роль + язык (расширенные настройки скрыты)
.executor + !isProgrammingProject → роль + язык + флаг типа проекта
.executor + isProgrammingProject → всё: git, тесты, архитектура, комментарии
```

**Алерт при downgrade:** executor → advisor → алерт → `downgradeToAdvisor()` сбрасывает все флаги

**Индикатор роли в чипе:**
- 🔒 (lock.fill) = advisor
- ⚡ (bolt.fill) = executor

---

## 5. ContentView — управление sheets

```swift
// Sheet настроек приложения
.sheet(isPresented: $showSettings) { SettingsView() }

// Sheet настроек проекта (IT-09)
.sheet(item: $selectedProjectForSettings) { project in
    ProjectSettingsSheet(
        project: project,
        onSave: { viewModel.updateProjectSettings($0, forProjectId: project.id) },
        onDismiss: { selectedProjectForSettings = nil }
    )
}
```

---

## 6. MCPHelperLauncher

Управляет жизненным циклом ChappieMCP дочернего процесса.

**Правило:** запускается ТОЛЬКО когда известен путь к воркспейсу:
- `loadWorkspaceWithSecurityScope()` → `launch(workspacePath:)`
- `setWorkspace()` → `restartWithWorkspace()`
- `ChappieApp.onAppear` НЕ вызывает launch() (путь ещё неизвестен)

---

## 7. Security-Scoped Bookmarks

Для каждой папки проекта создаётся security-scoped bookmark.
Хранится в `ProjectEntity.bookmarkData` (SwiftData).
При добавлении через инструмент `add_project_to_thread` — bookmark пустой (Data()).
Пользователь добавляет через UI с реальным bookmark.

---

## 📚 Changelog

| Date | Change |
|------|--------|
| 2026-05-26 | IT-09 ✅: ProjectSettingsSheet, ProjectChipsView.onOpenSettings, ContentView.sheet(item:), ChappieViewModel.updateProjectSettings(), buildAndSyncMemoryContext() с settings |
| 2025-07-XX | IT-06..IT-08 завершён: ProjectChipsView, плашки проектов, UUID-based память |
| 2025-07-XX | IT-05: SidebarView, ThreadListView, ThreadRowView |
