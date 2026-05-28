<!--
  Chappie/architecture.md

  ARCHITECTURE DOCUMENT — UI TARGET (Chappie.app)

  This file is the single source of architectural truth for the UI layer.
  Update after every significant architectural change.
-->

# Chappie.app — UI Layer Architecture

## 1. Purpose

**Chappie.app** is a thin SwiftUI shell over ChappieCore.
All business logic lives in ChappieCore. The UI target is responsible only for:
- Rendering data from ViewModel
- Handling user input
- Navigation and animations
- Launching the ChappieMCP helper

---

## 2. File Structure

```
Chappie/
├── ChappieApp.swift                    # @main, ModelContainer, onAppear
├── ContentView.swift                   # Conductor: assembles components, manages sheets
├── ChappieViewModel.swift              # @Observable @MainActor ViewModel
├── MCPHelperLauncher.swift             # Launches ChappieMCP child process
├── Models/
│   └── ChatMessage.swift               # UI message model (enum: .message / .toolCall)
├── Settings/
│   ├── SettingsView.swift              # App settings sheet (API key)
│   ├── SettingsManager.swift           # UserDefaults + Keychain for API key
│   └── KeychainManager.swift           # Keychain wrapper
└── Views/
    ├── Chat/
    │   ├── ChatScrollView.swift         # Message feed (LazyVStack, anti-jump streaming)
    │   ├── MessageBubbleView.swift      # Single message bubble (+ cost chip in cloud)
    │   ├── MarkdownTextView.swift       # Markdown → NSAttributedString renderer
    │   ├── ModelPickerRow.swift         # Provider/model picker + balance chip
    │   ├── StatusBarView.swift          # Status bar (current tool)
    │   ├── ProjectChipsView.swift       # [IT-06, IT-09] Project chips + gear chip for thread settings
    │   ├── ProjectSettingsSheet.swift   # [IT-09] Project settings sheet
    │   └── ThreadSettingsSheet.swift    # [IT-11] Thread settings sheet (name, context depth)
    ├── Input/
    │   ├── InputBarView.swift           # Input field + send button
    │   └── InputMorphView.swift         # Morphing input container
    ├── Providers/
    │   ├── ProvidersSettingsView.swift  # Provider list
    │   ├── AddProviderSheet.swift       # Add provider sheet
    │   └── NewThreadProviderSheet.swift # Provider picker sheet when creating a thread
    ├── Sidebar/
    │   ├── SidebarView.swift            # Sidebar container (header: "Треды" + "Новый" button)
    │   ├── ThreadListView.swift         # Thread list
    │   └── ThreadRowView.swift          # Single thread row (gear + trash on hover)
    ├── Toolbar/
    │   └── ToolbarContent.swift         # Toolbar: sidebar toggle + thread title + settings gear
    └── Onboarding/
        └── OnboardingView.swift         # Onboarding on first launch
```

---

## 3. ChappieViewModel

`@Observable @MainActor final class ChappieViewModel`

### Key Properties

| Property | Type | Purpose |
|----------|------|---------|
| `threads` | `[ThreadMetadata]` | All threads for the sidebar |
| `activeThread` | `ThreadMetadata?` | Currently active thread |
| `activeProjects` | `[ProjectMetadata]` | Projects of the active thread |
| `activeMemoryContext` | `MemoryContext` | Context for system prompt (IT-09: includes settings) |
| `messages` | `[ChatMessage]` | Full history (UI + legacy) |
| `visibleMessages` | `[ChatMessage]` | Depth-limited list for ChatScrollView (contextDepth × 10) |
| `isThinking` | `Bool` | Loading indicator |
| `streamingText` | `String` | Current streaming response |
| `runningCost` | `Double` | Accumulated request cost |
| `currentBalance` | `Double?` | Active provider balance (nil = not loaded) |
| `activeProvider` | `AIProvider?` | Active AI provider |
| `activeModelName` | `String?` | Selected model for the active provider |
| `activeThreadSettings` | `ThreadSettings` | Settings of the active thread (context depth, unlimited flag) |

### Key Methods

| Method | Purpose |
|--------|---------|
| `setModelContainer(_:)` | Connects SwiftData, registers handlers |
| `selectThread(_:)` | Loads thread + projects + syncs context + ALWAYS calls switchProvider() + saves lastActiveThreadId |
| `switchProvider(_:)` | Changes active provider, loads its balance from UserDefaults |
| `refreshBalanceForActiveProvider()` | Loads balance from UserDefaults on startup/thread switch |
| `addProject(url:)` | Adds a project via NSOpenPanel bookmark |
| `removeProject(id:)` | Removes a project from the thread |
| `updateProjectSettings(_:forProjectId:)` | **[IT-09]** Saves project settings |
| `updateThreadSettings(_:newTitle:forThreadId:)` | **[IT-11]** Saves thread name + context settings |
| `buildAndSyncMemoryContext()` | Assembles MemoryContext with settings (IT-09) |
| `syncActiveMemoryContext()` | Syncs ToolExecutionService (context + settings) |
| `send(prompt:)` | Sends a request to AIOrchestrator |

### Data Flow on Thread Switch

```
selectThread()
  → saveLastActiveThreadId()          ← UserDefaults key: "lastActiveThreadId"
  → loadProjectsForThread()           ← ProjectStore → activeProjects
  → switchProvider(savedOrDefault)    ← ALWAYS, even if provider didn't change
      → loadBalance(for: provider)    ← UserDefaults key: balance_<id>
  → buildAndSyncMemoryContext()       ← activeProjects → MemoryContext (with settings IT-09)
  → syncActiveMemoryContext()         ← ToolExecutionService.setActiveMemoryContext()
                                      ← ToolExecutionService.setProjectSettings() (IT-09)
```

### Critical Rule: selectThread() ALWAYS calls switchProvider()

**Reason (fixed bug):** previously `switchProvider()` was skipped if `activeProvider != nil`.
This caused the AI model to be set globally instead of per-thread.
Now: `selectThread()` always calls `switchProvider()` with the thread's saved provider
or the default — guaranteeing correct model and balance loading for each thread.

---

## 4. Provider Balance

**Storage:** UserDefaults, key `balance_<provider.id.uuidString>`
**Load:** `switchProvider()` → `loadBalance(for: provider)`
**Real-time update:** `onBalanceUpdate` callback in `AIOrchestrator.process()`
**Display:** `ModelPickerRow` — balance chip to the right of the model picker

---

## 5. ChatScrollView — LazyVStack + Anti-Jump Streaming

**Problem:** during streaming, `withAnimation` on every token triggered layout recalculation → jumps.

**Solution:**
- Streaming (`onChange(of: streamingText)`) → `proxy.scrollTo("bottom")` **without animation** (instant snap)
- Discrete events (new message, thread switch, isThinking) → `withAnimation(.easeOut)`
- `LazyVStack` — renders only visible messages (critical at 10,000 messages)
- Transparent spacers at top/bottom (`headerHeight`, `footerHeight`) — first/last message not hidden behind floating panels

**Visible message depth rule:**
- `visibleMessages = last (contextDepth × 10) messages`
- When `isUnlimitedContext = true` → all messages

---

## 6. ModelPickerRow

Floating panel for selecting provider and model. Located above the chat (not in toolbar).

**Components:**
- Provider picker (left side)
- Model picker (right side)
- Balance chip (far right, after Spacer)

**Display rules:**
- `.lineLimit(1)` on all Text — no wrapping on window resize
- `.fixedSize()` on model picker button — no height growth
- On narrow window — text truncates, does not wrap

---

## 7. IT-09: ProjectSettingsSheet

**Opened by:** tap on project chip in ProjectChipsView → `onOpenSettings(UUID)` → `ContentView.selectedProjectForSettings`

**Pattern:** "dumb component" — knows nothing about SwiftData.
- Receives `ProjectMetadata` and `onSave: (ProjectSettings) -> Void`
- Edits `@State draft: ProjectSettings` (a copy, not the original)
- On "Save" → `onSave(draft)` → `viewModel.updateProjectSettings()`

**Unlock logic:**
```
.advisor → role + language only (advanced settings hidden)
.executor + !isProgrammingProject → role + language + project type flag
.executor + isProgrammingProject → everything: git, tests, architecture, comments
```

**Downgrade alert:** executor → advisor → alert → `downgradeToAdvisor()` resets all flags

**Role indicator in chip:**
- 🔒 (lock.fill) = advisor
- ⚡ (bolt.fill) = executor

---

## 8. IT-11: ThreadSettingsSheet

**Opened from two places:**
1. Gear icon in `ThreadRowView` (hover/context menu) → `onOpenThreadSettings(thread)` → `ContentView.selectedThreadForSettings`
2. Gear chip in `ProjectChipsView` (right side, mirrors balance pill pattern) → `onOpenThreadSettings()` → same state

**Pattern:** same "dumb component" pattern as ProjectSettingsSheet.
- Receives `ThreadMetadata` (includes `settings` field since IT-11)
- Edits `@State draftTitle: String` and `@State draftSettings: ThreadSettings`
- On "Save" → `onSave(newTitle, newSettings)` → `viewModel.updateThreadSettings()`

**Settings:**
- Thread name (inline TextField)
- Context depth: slider 10...1000 messages
- Unlimited context toggle (bypasses all trimming)
- Info box: shows token budget (messages × 500) and chat display depth (messages × 10)

**Slider step:** adaptive — 5 at 10-100, 10 at 100-500, 50 at 500-1000

---

## 9. IT-11: Toolbar Thread Title

`ToolbarContent.swift` accepts `activeThreadTitle: String?` and renders:
```
[sidebar toggle]    Chappie — <thread name>    [settings gear]
```
Uses `.principal` placement (center of toolbar).
Hidden when `activeThreadTitle == nil` (onboarding state).
Title truncates with `.middle` mode at max 300pt width.

---

## 10. IT-11: Last Active Thread Restore (UX-RESTORE)

`selectThread()` saves `thread.id.uuidString` to UserDefaults key `"lastActiveThreadId"`.
`loadThreadsAndSelectActive()` on startup:
1. Tries to find thread by `lastActiveThreadId` → selects it.
2. Falls back to most recently updated thread (index 0, sorted by `updatedAt DESC`).

---

## 11. ContentView — Sheet Management

```swift
// App settings sheet
.sheet(isPresented: $showSettings) { SettingsView() }

// Project settings sheet (IT-09)
.sheet(item: $selectedProjectForSettings) { project in
    ProjectSettingsSheet(onSave: { viewModel.updateProjectSettings(...) }, ...)
}

// Thread settings sheet (IT-11)
.sheet(item: $selectedThreadForSettings) { thread in
    ThreadSettingsSheet(onSave: { title, settings in
        viewModel.updateThreadSettings(settings, newTitle: title, forThreadId: thread.id)
    }, ...)
}

// New thread provider picker
.sheet(isPresented: $viewModel.showNewThreadProviderPicker) { NewThreadProviderSheet(...) }
```

---

## 12. MCPHelperLauncher

Manages the lifecycle of the ChappieMCP child process.

**Rule:** launched ONLY when the workspace path is known:
- `loadWorkspaceWithSecurityScope()` → `launch(workspacePath:)`
- `setWorkspace()` → `restartWithWorkspace()`
- `ChappieApp.onAppear` does NOT call launch() (path not yet known)

---

## 13. Security-Scoped Bookmarks

A security-scoped bookmark is created for each project folder.
Stored in `ProjectEntity.bookmarkData` (SwiftData).
When added via `add_project_to_thread` tool — bookmark is empty (Data()).
User adds via UI with a real bookmark.

---

## 📚 Changelog

| Date | Change |
|------|--------|
| 2026-05-28 | IT-11 ✅: ThreadSettingsSheet, toolbar thread title, UX-RESTORE (last-thread restore), gear in ThreadRowView + ProjectChipsView, "Новый" label on sidebar button |
| 2026-05-26 | IT-09 ✅: ProjectSettingsSheet, ProjectChipsView.onOpenSettings, ContentView.sheet(item:) |
| 2026-05-XX | Bug fixed: input panel stuck in thinking state (isThinking=false inside withAnimation) |
| 2026-05-XX | Draft per thread (UX-DRAFT): threadDrafts [UUID: String] in ViewModel |
| 2026-05-XX | LazyVStack + anti-jump streaming in ChatScrollView; new thread button moved to sidebar header |
| 2026-05-XX | Bug fixed: selectThread() now ALWAYS calls switchProvider() (MODEL-PER-THREAD) |
| 2026-05-XX | Balance per-provider: UserDefaults key balance_<id>, ModelPickerRow chip |
| 2025-07-XX | IT-06..IT-08 done: ProjectChipsView, project chips, UUID-based memory |
| 2025-07-XX | IT-05: SidebarView, ThreadListView, ThreadRowView |
