<!--
  Chappie/architecture.md

  ДОКУМЕНТ АРХИТЕКТУРЫ — UI ТАРГЕТ (Chappie.app)

  Этот файл — единственный источник архитектурной документации для UI-таргета.
  Обновляй при каждом значимом архитектурном изменении.
-->

# Chappie.app — Архитектура UI-таргета

## 1. Назначение

**Chappie.app** — тонкая SwiftUI-оболочка над ChappieCore.
Вся бизнес-логика — в ChappieCore. App-таргет отвечает только за UI.

---

## 2. Структура файлов

```
Chappie/
├── architecture.md                     # Этот файл
├── ChappieApp.swift                    # @main точка входа, ModelContainer
├── ChappieViewModel.swift              # @Observable @MainActor ViewModel
├── ContentView.swift                   # "Дирижёр" — собирает компоненты
│
├── Models/
│   └── ChatMessage.swift               # UI-модель сообщения (enum с associated values)
│
├── Views/
│   ├── Sidebar/
│   │   ├── SidebarView.swift           # Боковая панель (только треды)
│   │   ├── ThreadListView.swift        # Список тредов (ForEach)
│   │   └── ThreadRowView.swift         # Строка треда (hover/rename/delete)
│   ├── Chat/
│   │   ├── ProjectChipsView.swift      # Чипы проектов над чатом (IT-06)
│   │   ├── ChatScrollView.swift        # Лента сообщений
│   │   ├── MessageBubbleView.swift     # Пузырь одного сообщения
│   │   ├── MarkdownTextView.swift      # Рендер Markdown
│   │   └── StatusBarView.swift         # Строка текущего инструмента
│   ├── Input/
│   │   └── InputBarView.swift          # Поле ввода + кнопка отправки
│   └── Toolbar/
│       └── ToolbarContent.swift        # Тулбар: баланс + настройки
│
└── Settings/
    ├── SettingsView.swift              # Экран настроек (API-ключ, воркспейс)
    ├── SettingsManager.swift           # UserDefaults обёртка
    └── KeychainManager.swift           # Keychain для API-ключа
```

---

## 3. Архитектурные принципы

### "Тупой дирижёр" (ContentView)
ContentView НЕ содержит бизнес-логику. Только собирает компоненты и прокидывает
данные из ViewModel в View и коллбэки обратно.

### "Тупые компоненты" (все View)
Все View получают данные через параметры, все действия — через коллбэки.
Никакой прямой работы с SwiftData, ThreadStore, ProjectStore в View.

### @Observable + @MainActor
ChappieViewModel — единственная точка состояния UI.
@Observable (Swift 5.9+) даёт точечные перерисовки (только изменившиеся свойства).
@MainActor гарантирует безопасность обновлений из async-контекста.

---

## 4. Тулбар (UI-FIX-02)

**Состав тулбара:** только баланс (если загружен) + кнопка настроек ⚙️.

**ПОЧЕМУ НЕТ ВОРКСПЕЙСА В ТУЛБАРЕ:**
Воркспейс — техническая настройка (рабочая папка для инструментов read_file/write_file).
Она не связана с тредами и проектами пользователя.
Её место — в SettingsView, а не в основном тулбаре.
Тулбар должен быть минималистичным.

**ВИЗУАЛЬНЫЙ СИГНАЛ:**
Шестерёнка ⚙️ становится оранжевой если API-ключ не задан.
Это мягкое напоминание без агрессивных алертов.

---

## 5. Боковая панель (IT-05)

**Содержит ТОЛЬКО треды** — как в ChatGPT/Claude.

**Поведение:**
- Список тредов отсортирован по updatedAt DESC (свежий — сверху)
- Активный тред подсвечивается акцентным цветом
- Hover → кнопка удаления
- Двойной клик → inline переименование
- Правый клик → контекстное меню (переименовать, удалить)
- Кнопка "Новый тред" закреплена внизу
- При удалении последнего треда → автосоздание нового

**ПОЧЕМУ НЕТ ВОРКСПЕЙСА В САЙДБАРЕ:**
Воркспейс — глобальная настройка приложения, не per-тред навигация.
Смешивать их в одной панели создаёт путаницу.

---

## 6. Плашки проектов (IT-06, UI-FIX-02)

**Компонент:** `ProjectChipsView` — над лентой сообщений.

**Видимость:**
Показывается ТОЛЬКО когда `viewModel.activeThread != nil`.
Без треда — строка не отображается (нет смысла добавлять проекты без контекста).
Приложение всегда автоматически выбирает/создаёт тред при старте.

**Поведение чипов:**
- Горизонтальный скролл
- Hover → кнопка "×" для удаления проекта из треда
- Кнопка "+" → NSOpenPanel → выбор папки → addProject(url:)
- При удалении — UUID убирается из projectBindingsJSON (ProjectEntity НЕ удаляется)

**ПОЧЕМУ NSOpenPanel, А НЕ .fileImporter:**
.fileImporter в SwiftUI не позволяет настроить canChooseFiles: false, canChooseDirectories: true.
NSOpenPanel даёт полный контроль над диалогом выбора папки.

---

## 7. Воркспейс (рабочая папка)

**Что это:** папка проекта для инструментов read_file/write_file/list_files.
**Хранится:** security-scoped bookmark в UserDefaults ("workspaceBookmark").
**Восстанавливается:** при старте через `loadWorkspaceWithSecurityScope()`.
**Выбирается:** через SettingsView (TODO: добавить кнопку в Settings).

**ОТЛИЧИЕ ОТ "ПРОЕКТА ТРЕДА":**
Воркспейс — один на всё приложение, технический.
Проект треда (ProjectEntity) — per-тред, для контекста памяти.
Это разные концепции!

---

## 8. SwiftData (IT-01..IT-06)

**ModelContainer создаётся в ChappieApp.swift** и передаётся через `.modelContainer()`.
**ContentView.onAppear** вызывает `viewModel.setModelContainer(modelContext.container)`.
**setModelContainer() идемпотентен** — повторные вызовы игнорируются.

**Сторы создаются в ViewModel:**
- `MemoryStore` — трёхуровневая память (global/project/thread)
- `ThreadStore` — треды и их история
- `ProjectStore` — проекты

---

## 9. Система памяти и system prompt

**Три уровня памяти (IT-03):**
1. Глобальная (scope="global") — факты о пользователе, стиль общения
2. Проектная (scope="<projectId>") — архитектура проекта, договорённости
3. Тредовая (scope="<threadId>") — контекст текущей задачи

**Автоматическое подмешивание:**
`MemoryManager.buildSystemPrompt()` вызывается перед каждым запросом.
Чаппи ВСЕГДА видит всю свою память — не нужно явно вызывать recall.

**MemoryContext:**
```swift
struct MemoryContext: Sendable {
    let threadId: UUID?      // для тредовой памяти
    let projectIds: [UUID]   // для проектной памяти
}
```
Заполняется из `activeThread` при выборе треда.

---

## 📚 Changelog

| Date | Change |
|------|--------|
| 2025-07-XX | UI-FIX-02: убрана кнопка воркспейса из тулбара, упрощён ProjectChipsView (убран isThreadActive), плашки показываются только при activeThread != nil |
| 2025-07-XX | UI-FIX-01: убрана секция воркспейса из SidebarView, добавлена в тулбар (отменено в UI-FIX-02) |
| 2025-07-XX | IT-07: инструменты add/remove/list_thread_projects, registerProjectHandlers() |
| 2025-07-XX | IT-06: ProjectChipsView, addProject/removeProject в ViewModel |
| 2025-07-XX | IT-05: ThreadListView, ThreadRowView, SidebarView с тредами |
| 2025-07-XX | IT-04: MigrationService, setModelContainer() в ViewModel |
| 2025-07-XX | IT-03: MemoryStore, buildSystemPrompt(), MemoryContext |
| 2025-07-XX | IT-02: динамический AppConfig, activeThreadSettings |
| 2025-07-XX | IT-01: SwiftData модели, ModelContainer в ChappieApp |
