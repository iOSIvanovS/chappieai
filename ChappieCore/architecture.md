<!--
  ChappieCore/architecture.md

  ARCHITECTURE DOCUMENT — CHAPPIECORE (BUSINESS LOGIC)

  This file is the single source of architectural truth for ChappieCore.
  Update after every significant architectural change.
-->

# ChappieCore — Library Architecture

## 1. Purpose

**ChappieCore** is a Swift Package Library containing all of Chappie's business logic.
The `Chappie.app` UI target is a thin shell — ChappieCore does all the real work.

### Isolation Principle

- **No UIKit/SwiftUI** in ChappieCore — Foundation and system frameworks only.
- **All services are actors** (`actor`) for safe concurrent access in Swift 6.
- **Public API** — only what the UI target needs. Implementation details are `internal`.

---

## 2. File Structure

```
ChappieCore/Sources/ChappieCore/
├── ChappieCore.swift                   # Public library facade
├── Models/
│   ├── AITunnelModels.swift            # AIMessage, AIToolCall, AIStreamResult, etc.
│   ├── AppConfig.swift                 # Configuration: tokens, limits, model
│   ├── ChappieError.swift              # Typed errors
│   ├── ThreadModels.swift              # [IT-01, IT-10] ThreadEntity, ThreadSettings
│   ├── ProjectModels.swift             # [IT-01, IT-09] ProjectEntity, ProjectSettings + enums
│   └── MemoryModels.swift              # [IT-01] MemoryEntity, MemoryEntry, ActiveMemoryContext
└── Services/
    ├── AIOrchestrator.swift            # Agent loop + MemoryContext with project settings
    ├── AITunnelClient.swift            # HTTP client for AITunnel API (SSE streaming)
    ├── AIClient.swift                  # Universal AI client (OpenAI-compatible)
    ├── AIProviderModels.swift          # AIProvider, AIProviderStore — per-provider settings
    ├── AIProviderStore.swift           # CRUD for AIProvider in UserDefaults
    ├── ChatHistoryManager.swift        # [DEPRECATING → BL-01] JSON chat history storage
    ├── FileSystemManager.swift         # File read/write (with Path Traversal protection)
    ├── MCPToolBridge.swift             # Unix Domain Socket client to ChappieMCP
    ├── MemoryManager.swift             # Semantic memory + buildSystemPrompt with Settings
    ├── MemoryStore.swift               # [IT-01] SwiftData CRUD for three-level memory
    ├── ToolExecutionService.swift      # Tool dispatcher + permission check (IT-09)
    ├── ThreadStore.swift               # [IT-01] CRUD for threads via SwiftData
    ├── ProjectStore.swift              # [IT-01] CRUD for projects via SwiftData
    └── MigrationService.swift          # [IT-04] Migrates chat_history.json → SwiftData
```

---

## 3. Key Services

### AIOrchestrator
The main orchestration component. Implements the agent loop:
`request → streamRequestWithTools → tool_calls? → execute → repeat → final response`

**Key decisions:**
- Single streaming loop (not two requests probe+stream)
- Smart context window: tokenBudget + maxMessagesInContext
- Old message compression via `<summary>` tag
- Loop protection: consecutive-block guard (lastToolSignature)
- **[IT-02]** Accepts `config: AppConfig` as parameter
- **[IT-03]** Accepts `memoryContext: MemoryContext` for three-level memory
- **[IT-09]** `MemoryContext.ProjectInfo` extended with `settings: ProjectSettings?`
- **onBalanceUpdate callback** — called when new balance is received during streaming

### MemoryManager
Manages the workspace memory file structure.

**[IT-09] buildSystemPrompt() — prompt structure:**
```
[base prompt]

---
## Memory Context

## Project Settings: Chappie          ← IT-09: agent permissions (FIRST!)
- Role: EXECUTOR
- Git: write [git_status, git_add, ...]
...

## Global Memory                       ← global memory
## Project Memory: Chappie             ← project memory
## Thread Context                      ← thread memory
```

**Block order:** Settings → Global → Project Memory → Thread
**Why Settings first:** the agent must know its constraints BEFORE processing memory.

### ToolExecutionService [IT-09]
Tool dispatcher with permission checks.

**Check order in execute():**
1. **PROJECT GUARD** — file/git/build tools require a project in the thread
2. **TOOL ACCESS CHECK** — `checkToolAccess()` validates ProjectSettings
3. Execute the tool

**checkToolAccess() logic:**
- `git_diff` → always FORBIDDEN (hard ban)
- Role `.advisor` → only `list_files, read_file, read_build_log`
- Git tools → check `GitAccessLevel.allowedTools`
- Build/tests → check `TestsAccessLevel.canRun`

**setProjectSettings([UUID: ProjectSettings])** — settings cache.
Called from `ChappieViewModel.syncActiveMemoryContext()`.
Settings taken from the first project in the thread (MVP simplification).

---

## 4. AIProvider — Multi-Provider Architecture

**Model:** `AIProvider` stores endpoint, API key, model list.
**Storage:** `AIProviderStore` — SwiftData (or UserDefaults, clarify on change).
**Per-thread selection:** `ThreadSettings.activeProviderId` + `ThreadSettings.activeModelName`

**Provider balance:**
- Stored in UserDefaults: key `balance_<provider.id.uuidString>`
- Type: `Double?` (nil = not loaded)
- Old key `savedBalance` — removed

**Balance currency:**
- Hardcoded as `₽` in UI (ModelPickerRow)
- AITunnel API returns only `Double` with no currency field
- Backlog BL-03: universal balance support for top-10 providers

---

## 5. IT-09: ProjectSettings — Agent Permissions

### Models

```swift
AgentRole: .advisor | .executor
GitAccessLevel: .none | .statusOnly | .write | .full
TestsAccessLevel: .none | .readOnly | .run | .write
ProjectLanguage: .english | .native
```

### ProjectSettings Fields

```swift
// Core (always present)
agentRole: AgentRole = .advisor      // SAFE DEFAULT
preferredLanguage: String?

// Project type
isProgrammingProject: Bool = false   // Unlocks advanced settings

// Advanced (only when isProgrammingProject = true)
gitAccess: GitAccessLevel = .none
testsAccess: TestsAccessLevel = .none
architectureEnabled: Bool = false
architectureLanguage: ProjectLanguage = .english
commentsEnabled: Bool = false
commentsLanguage: ProjectLanguage = .english
```

### Rules

- `git_diff` is NEVER allowed at any GitAccessLevel — hard ban
- On executor → advisor downgrade: `downgradeToAdvisor()` resets ALL flags
- Settings stored in `ProjectEntity.settingsJSON` (SwiftData)
- `formatForSystemPrompt(projectName:)` → permissions block for prompt

---

## 6. Three-Level Memory (IT-03, IT-08 ✅)

### Levels and Scopes

| Level | Scope in SwiftData | Tool |
|-------|--------------------|------|
| Global | `"global"` | memorize(scope="global") |
| Project | `"<projectId UUID>"` | memorize(targetName="Chappie") |
| Thread | `"<threadId UUID>"` | memorize(scope="thread") |

### Memory Tools — Final API (IT-08 ✅)

- `scope="global"` → MemoryStore.saveEntry(scope: "global")
- `scope="thread"` → MemoryStore.saveEntry(scope: threadId.uuidString)
- `targetName="Chappie"` → find project by name → saveEntry(scope: projectId.uuidString)

**Mandatory rules:**
- `scope="project"` — REMOVED (ambiguous with multiple projects)
- Project memory REQUIRES explicit `targetName`
- If targetName not found — error with hint

---

## 7. Agent Loop (Details)

```
process(prompt:history:config:memoryContext:onToolCall:onToken:onBalanceUpdate:)
    ↓
buildSystemPrompt(basePrompt:memoryContext:)
    → Settings blocks (IT-09)
    → Global Memory
    → Project Memory blocks
    → Thread Context
    ↓
buildContextWindow()
    ↓
while stepCount < maxSteps:
    streamRequestWithTools()
        ↓ onToken → UI
        ↓ onBalanceUpdate → ChappieViewModel.currentBalance
    if toolCalls:
        executeToolCalls()
            → checkToolAccess() (IT-09)
            → ToolExecutionService.execute()
        continue
    else:
        return finalResponse
```

---

## 8. SwiftData Schema

```swift
ThreadEntity
├── id: UUID
├── title: String
├── createdAt/updatedAt: Date
├── messagesJSON: Data          ← [ChatMessage]
├── settingsJSON: Data          ← ThreadSettings (includes activeProviderId, activeModelName)
└── projectBindingsJSON: Data   ← [UUID]

ProjectEntity
├── id: UUID
├── displayName: String
├── bookmarkData: Data          ← security-scoped bookmark
├── createdAt: Date
└── settingsJSON: Data          ← ProjectSettings (IT-09: extended)

MemoryEntity
├── id: UUID
├── scope: String               ← "global" | "<projectId>" | "<threadId>"
└── entriesJSON: Data           ← [MemoryEntry]
```

---

## 9. Context Window (AppConfig Parameters)

| Parameter | Source | Range |
|-----------|--------|-------|
| `maxMessagesInContext` | `ThreadSettings` | 10...1000 |
| `tokenBudget` | `maxMessages × 500` | 5,000...500,000 |
| `isUnlimitedContext` | `ThreadSettings` | true → Int.max for both |
| `recentFullMessages` | Hardcoded (3) | — |
| `summaryThreshold` | Hardcoded (400) | — |
| `maxOrchestratorSteps` | Hardcoded (20) | — |

**When isUnlimitedContext = true:** `maxMessages = Int.max`, `tokenBudget = Int.max` — context is never trimmed.

---

## 10. Prompt Caching

**TOP-LEVEL cache_control:**
```json
{ "cache_control": { "type": "ephemeral", "ttl": "1h" } }
```
TTL 1h is optimal for development. FORBIDDEN: per-block cache_control (breaks the gateway).

---

## 11. ChatHistoryManager — DEPRECATING (BL-01)

Current state: JSON file, 100-message limit hardcoded.
Planned: migrate to SwiftData with dynamic limit = `contextDepth × 10`.
When `isUnlimitedContext = true` — store all messages.

---

## 12. Tech Debt

| # | Description | Priority | Status |
|---|-------------|----------|--------|
| TD-TEST | Unit tests for key services | 🟡 | 🔲 Open |

---

## 📚 Changelog

| Date | Change |
|------|--------|
| 2026-07-XX | Architecture files translated to English |
| 2026-07-XX | IT-10 ✅: ThreadSettings.activeProviderId + activeModelName, maxMessages range extended to 10...1000, isUnlimitedContext |
| 2026-07-XX | AIClient + AIProviderStore: multi-provider architecture, per-provider balance |
| 2026-07-XX | onBalanceUpdate callback in AIOrchestrator.process() |
| 2026-05-26 | IT-09 ✅: ProjectSettings, formatForSystemPrompt(), ToolExecutionService.checkToolAccess() |
| 2025-07-XX | IT-08 ✅: UUID-based scope, ActiveMemoryContext |
| 2025-07-XX | REFACTOR-THREADS IT-01..IT-07 complete |
